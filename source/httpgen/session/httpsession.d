/*
 * Collie - An asynchronous event-driven network framework using Dlang development
 *
 * Copyright (C) 2015-2017  Shanghai Putao Technology Co., Ltd 
 *
 * Developer: putao's Dlang team
 *
 * Licensed under the Apache-2.0 License.
 *
 */
module httpgen.session.httpsession;

import httpgen.headers;
import httpgen.httpmessage;
import httpgen.httptansaction;
import httpgen.codec.httpcodec;
import httpgen.codec.wsframe;
import httpgen.errocode;

import std.socket;
import yu.memory.allocator;
import yu.memory.smartref;
import containers.hashmap;

import std.experimental.logger;
import yu.container.string;


abstract class HTTPSessionController
{
    HTTPTransactionHandler getRequestHandler(HTTPSession.SharedTansaction txn, HTTPMessage msg);

	void attachSession(HTTPSession session){}
	
	/**
   * Informed at the end when the given HTTPSession is going away.
   */
	void detachSession(HTTPSession session){}
	
	/**
   * Inform the controller that the session's codec changed
   */
	void onSessionCodecChange(HTTPSession session) {}
}

interface SessionDown
{
	void httpWrite(ubyte[],void delegate(ubyte[],size_t));
	void httpClose();
	void post(void delegate());
	Address localAddress();
	Address remoteAddress();
}

/// HTTPSession will not send any read event
abstract class HTTPSession : HTTPTransaction.Transport,
	HTTPCodec.CallBack
{
	alias StreamID = HTTPCodec.StreamID;
    alias SharedHttpMsg = ISharedRef!(YuAlloctor,HTTPMessage,false);
    alias SharedTansaction = ISharedRef!(YuAlloctor, HTTPTransaction, false);
    alias TansactionMap = HashMap!(StreamID,SharedTansaction,YuAlloctor,generateHash!StreamID,false);
    alias SharedCallback = HTTPCodecBuffer.SharedCallback;

	interface InfoCallback {
		// Note: you must not start any asynchronous work from onCreate()
		void onCreate(HTTPSession);
		//void onIngressError(const HTTPSession, ProxygenError);
		void onIngressEOF();
		void onRequestBegin(HTTPSession);
		void onRequestEnd(HTTPSession,
			uint maxIngressQueueSize);
		void onActivateConnection(HTTPSession);
		void onDeactivateConnection(HTTPSession);
		// Note: you must not start any asynchronous work from onDestroy()
		void onDestroy(HTTPSession);
	}


	this(HTTPSessionController controller,HTTPCodec codec,SessionDown down)
	{
        _transaction = TansactionMap(yuAlloctor);
		_controller = controller;
		_down = down;
		_codec = codec;
		_codec.setCallback(this);
	}

    mixin EnableSharedFromThisImpl!(YuAlloctor,HTTPSession,true);

    SharedCallback sharedCallBackThis()
    {
        auto sthis = sharedFromThis();
        return sthis.castTo!(HTTPCodec.CallBack)();
    }

//	//HandlerAdapter {
//	void onRead(ubyte[] msg) {
//		//trace("on read: ", cast(string)msg);
//		_codec.onIngress(msg);
//	}
//
//	void onActive() {
//		_localAddr = _down.localAddress;
//		_peerAddr = _down.remoteAddress;
//	}
//
//	void inActive() {
//		getCodec.onConnectClose();
//		trace("connect closed!");
//	}
//
//	void onTimeout() @trusted {
//		if(_codec)
//			_codec.onTimeOut();
//	}
//
//	//HandlerAdapter}
//	//HTTPTransaction.Transport, {

    final override void send(HTTPTransaction txn,
        HTTPMessage headers,in ubyte[] body_,
        bool eom)
    {
        auto id = txn.getID;
        HTTPCodecBuffer buffer = _codec.generateHeader(id,headers,0,(eom && body_.length == 0));
        if(buffer is null) 
            return;
        if(body_.length > 0)
            buffer = _codec.generateBody(id,body_,buffer,eom);
        buffer.setCallback(sharedCallBackThis());
        // TODO send buffer;
    }
    
    final override void sendBody(HTTPTransaction txn,
        in ubyte[] body_,
        bool eom)
    {
        HTTPCodecBuffer buffer = null;
        if(body_.length > 0)
            buffer = _codec.generateBody(txn.getID,body_,buffer,eom);
        if(buffer is null) 
            return;
        buffer.setCallback(sharedCallBackThis());
        // TODO send buffer;
    }

    // TODO: send file
    //      size_t sendIODevice(HTTPTransaction txn,
    //            HTTPMessage headers,
    //            IODevice device);
    
    final override void sendChunkBody(HTTPTransaction txn,
        size_t length,in ubyte[] body_,
        bool eom)
    {
        auto id = txn.getID;
        HTTPCodecBuffer buffer = null;
        if(length > 0){
            buffer = _codec.generateChunkHeader(id,length,buffer);
            buffer = _codec.generateBody(txn.getID,body_,buffer,eom);
        } else {
            buffer = _codec.generateEOM(id, buffer);
        }
        if(buffer is null) 
            return;
        buffer.setCallback(sharedCallBackThis());
        // TODO send buffer;
    }

    
    final override void sendWsData(HTTPTransaction txn,OpCode code,in ubyte[] data)
    {
        HTTPCodecBuffer buffer = null;
        buffer = _codec.generateWsFrame(txn.getID,code,data,buffer);
        if(buffer is null) 
            return;
        buffer.setCallback(sharedCallBackThis());
        // TODO send buffer;
    }

	
	final override void detach(HTTPTransaction txn)
	{
        _transaction.remove(txn.getID);
	}

	override HTTPCodec getCodec(){
		return _codec;
	}

	void restCodeC(HTTPCodec codec){
		if(_codec)
			_codec.setCallback(null);
		codec.setCallback(this);
		_codec = codec;
	}

    override void onMessageBegin(StreamID id, HTTPMessage msg);
	{
	}

    override void onHeadersComplete(StreamID id, HTTPMessage msg){
        if(!msg) return;
		trace("onHeadersComplete ------");
        auto tx = makeIScopedRef!HTTPTransaction(yuAlloctor,TransportDirection.DOWNSTREAM,id,0);
        auto header = SharedHttpMsg(yuAlloctor,msg);
		msg.clientAddress = getPeerAddress();
        msg.dstAddress = getLocalAddress();
        _transaction[id] = tx;
        setupOnHeadersComplete(tx,header);
	}

    override void onNativeProtocolUpgrade(StreamID id,
        CodecProtocol protocol,
        String protocolString,
        HTTPMessage msg)
    {
        if(!msg) return;
        trace("onNativeProtocolUpgrade ------");
        auto tx = makeIScopedRef!HTTPTransaction(yuAlloctor,TransportDirection.DOWNSTREAM,id,0);
        auto header = SharedHttpMsg(yuAlloctor,msg);
        msg.clientAddress = getPeerAddress();
        msg.dstAddress = getLocalAddress();
        _transaction[id] = tx;
        setupProtocolUpgrade(tx,protocol,protocolString, header);
    }

    override void onBody(StreamID id,const ubyte[] data){
        auto txn = _transaction.get(id, SharedTansaction());
        if(!txn.isNull)
			txn.onIngressBody(data);
	}

    override void onChunkHeader(StreamID id, size_t length)
    {}

    override void onChunkComplete(StreamID id)
    {}


    void onMessageComplete(StreamID id, bool upgrade){
        auto txn = _transaction.get(id, SharedTansaction());
        if(!txn.isNull)
			txn.onIngressEOM();
	}

    override void onError(StreamID id,HTTPErrorCode code){
        auto txn = _transaction.get(id, SharedTansaction());
        if(!txn.isNull)
            txn.onError(code);
	}

    override void onWsFrame(StreamID id,ref WSFrame wsf){
        auto txn = _transaction.get(id, SharedTansaction());
        if(!txn.isNull)
            txn.onWsFrame(wsf);
	}

    override void onSend(size_t shoudleSend, size_t sended)
    {}

protected:
	/**
   * Called by onHeadersComplete(). This function allows downstream and
   * upstream to do any setup (like preparing a handler) when headers are
   * first received from the remote side on a given transaction.
   */
	void setupOnHeadersComplete(ref SharedTansaction txn,
		ref SharedHttpMsg msg);

    void setupProtocolUpgrade(ref SharedTansaction txn,CodecProtocol protocol, ref String protocolString,
        ref SharedHttpMsg msg);

protected:
	String _localAddr;
    String _localPort;
    String _peerAddr;
    String _peerPort;
	HTTPCodec _codec;
    TansactionMap _transaction;

	HTTPSessionController _controller;
	SessionDown _down;
}

