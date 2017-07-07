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
module httpgen.codec.httpcodec;

import httpgen.httpmessage;
import httpgen.errocode;
import httpgen.codec.wsframe;
import httpgen.httptansaction;
import yu.asyncsocket.tcpsocket;
import yu.memory.sharedref;
import yu.exception;
import yu.memory.allocator;
import yu.container.string;

enum CodecProtocol : ubyte {
	init = 0,
	HTTP_1_X = 1,
	WEBSOCKET = 2,
	HTTP_2 = 3
};

final class HTTPCodecBuffer : TCPWriteBuffer
{
    import yu.container.vector;
    import yu.exception;
    import yu.memory.allocator;
    import std.experimental.allocator.mallocator;
    
    alias BufferData = Vector!(ubyte, Mallocator,false);
    alias SharedCallback =  ISharedRef!(YuAlloctor, HTTPCodec.CallBack,true);

    final setCallback(SharedCallback cback)
    {
        _cback.swap(cback);
    }

    override ubyte[] data() nothrow {
        auto dt = _data.data();
        return cast(ubyte[])dt[sended..$];
    }
    
    override void doFinish() nothrow {
        auto ptr = this;
        if(!_cback.isNull){
            yuCathException((){
                    _cback.onSend(_data.length,sended);
                    _cback.clear();
                }());   
        }
        yuCathException(yDel(ptr));
    }
    
    override bool popSize(size_t size) nothrow {
        sended += size;
        if(sended >= _data.length)
            return true;
        else
            return false;
    }
    
    void put(in ubyte[] data)
    {
        _data.put(data);
    }
    
private:
    BufferData _data;
    size_t sended = 0;
private:
    SharedCallback _cback; //  session 引用技术，防止提前释放
}

abstract class HTTPCodec
{
	/**
   * Key that uniquely identifies a request/response pair within
   * (and only within) the scope of the codec.  Code outside the
   * codec should regard the StreamID as an opaque data
   * structure; different subclasses of HTTPCodec are likely to
   * use different conventions for generating StreamID values.
   *
   * A value of zero indicates an uninitialized/unknown/unspecified
   * StreamID.
   */
	alias StreamID = uint;

	interface CallBack 
	{
		/**
     * Called when a new message is seen while parsing the ingress
     * @param stream   The stream ID
     * @param msg      A newly allocated HTTPMessage
     */
	 void onMessageBegin(StreamID id, HTTPMessage msg);
		/**
     * Called when a new push message is seen while parsing the ingress.
     *
     * @param stream   The stream ID
     * @param assocStream The stream ID of the associated stream,
     *                 which can never be 0
     * @param msg      A newly allocated HTTPMessage
     */
//	void onPushMessageBegin(StreamID id,
//		StreamID assocStream,
//			HTTPMessage* msg);
//		
		/**
     * Called when all the headers of an ingress message have been parsed
     * @param stream   The stream ID
     * @param msg      The message
     * @param size     Size of the ingress header
     */
        // shoudle delete HTTPMessage
	void onHeadersComplete(StreamID id,
		HTTPMessage msg);
		
		/**
     * Called for each block of message body data
     * @param stream  The stream ID
     * @param chain   One or more buffers of body data. The codec will
     *                remove any protocol framing, such as HTTP/1.1 chunk
     *                headers, from the buffers before calling this function.
     * @param padding Number of pad bytes that came with the data segment
     */
		void onBody(StreamID id,const ubyte[] data);
		
		/**
     * Called for each HTTP chunk header.
     *
     * onChunkHeader() will be called when the chunk header is received.  As
     * the chunk data arrives, it will be passed to the callback normally with
     * onBody() calls.  Note that the chunk data may arrive in multiple
     * onBody() calls: it is not guaranteed to arrive in a single onBody()
     * call.
     *
     * After the chunk data has been received and the terminating CRLF has been
     * received, onChunkComplete() will be called.
     *
     * @param stream    The stream ID
     * @param length    The chunk length.
     */
		void onChunkHeader(StreamID id, size_t length);
		
		/**
     * Called when the terminating CRLF is received to end a chunk of HTTP body
     * data.
     *
     * @param stream    The stream ID
     */
		void onChunkComplete(StreamID id);
		
		/**
     * Called at end of a message (including body and trailers, if applicable)
     * @param stream   The stream ID
     * @param upgrade  Whether the connection has been upgraded to another
     *                 protocol.
     */
		void onMessageComplete(StreamID id, bool upgrade);
		
		/**
     * Called when a parsing or protocol error has occurred
     * @param stream   The stream ID
     * @param error    Description of the error
     * @param newTxn   true if onMessageBegin has not been called for txn
     */
		void onError(StreamID id,HTTPErrorCode);
		
		/**
     * Called when the peer has asked to shut down a stream
     * immediately.
     * @param stream   The stream ID
     * @param code     The code the stream was aborted with
     * @note  Not applicable to all protocols.
     */
		void onAbort(StreamID id,
			HTTPErrorCode code);

        void onWsFrame(StreamID id ,ref WSFrame);
		
		/**
     * Called upon receipt of a valid protocol switch.  Return false if
     * protocol switch could not be completed.
     */
        // shoudle delete HTTPMessage
		void onNativeProtocolUpgrade(StreamID id,
			CodecProtocol protocol,
			String protocolString,
			HTTPMessage msg);

        // check to close and check other to send.
        void onSend(size_t shoudleSend, size_t sended);
	}

	CodecProtocol getProtocol();

	StreamID createStream();
	/**
   * Get the transport direction of this codec:
   * DOWNSTREAM if the codec receives requests from clients or
   * UPSTREAM if the codec sends requests to servers.
   */
	TransportDirection getTransportDirection();
	

	
	/**
   * Set the callback to notify on ingress events
   * @param callback  The callback object
   */
	void setCallback(CallBack callback);
	

	bool shouldClose();

    void checkSend(){}
	
	/**
   * Parse ingress data.
   * @param  buf   A single IOBuf of data to parse
   * @return Number of bytes consumed.
   */
	size_t onIngress(ubyte[] buf);


	void detach(StreamID id);
	/**
   * Finish parsing when the ingress stream has ended.
   */

    void onIngressEOF(){}
	
/**
   * Invoked on a codec that has been upgraded to via an HTTPMessage on
   * a different codec.  The codec may return false to halt the upgrade.
   */
	bool onIngressUpgradeMessage(const HTTPMessage msg) {
		return true;
	}

	/**
   * Write an egress message header.  For pushed streams, you must specify
   * the assocStream.
   * @retval size the size of the generated message, both the actual size
   *              and the size of the uncompressed data.
   * @return None
   */
    HTTPCodecBuffer generateHeader(
		StreamID id,
		scope HTTPMessage msg,
        StreamID assocStream = 0,
        bool eom = false){
        return null;
    }
	
	/**
   * Write part of an egress message body.
   *
   * This will automatically generate a chunk header and footer around the data
   * if necessary (e.g. you haven't manually sent a chunk header and the
   * message should be chunked).
   *
   * @param padding Optionally add padding bytes to the body if possible
   * @param eom implicitly generate the EOM marker with this body frame
   *
   * @return number of bytes written
   */
    HTTPCodecBuffer generateBody(StreamID id,
        in ubyte[] data,HTTPCodecBuffer buffer,
        bool eom){
        return null;
    }

	/**
   * Write a body chunk header, if relevant.
   */
    HTTPCodecBuffer generateChunkHeader(
		StreamID id,
        size_t length,HTTPCodecBuffer buffer = null){
        return null;
    }
	
	/**
   * Write a body chunk terminator, if relevant.
   */
    HTTPCodecBuffer generateChunkTerminator(
        StreamID id,HTTPCodecBuffer buffer = null){
        return null;
    }

	/**
   * Generate any protocol framing needed to finalize an egress
   * message. This method must be called to complete a stream.
   *
   * @return number of bytes written
   */
    HTTPCodecBuffer generateEOM(StreamID id,HTTPCodecBuffer buffer = null){
        return null;
    }
	
	/**
   * Generate any protocol framing needed to abort a connection.
   * @return number of bytes written
   */
    HTTPCodecBuffer generateRstStream(StreamID id,HTTPErrorCode code,HTTPCodecBuffer buffer = null){
        return null;
    }


    HTTPCodecBuffer generateWsFrame(StreamID id,OpCode code,in ubyte[] data,HTTPCodecBuffer buffer = null)
	{
		return null;
	}

	static CodecProtocol getProtocolFormString(string str)
	{
		import yu.string;
		if(isSameIngnoreLowUp(str,"websocket")){
			return CodecProtocol.WEBSOCKET;
        } else if(isSameIngnoreLowUp(str,"H2C") || isSameIngnoreLowUp(str,"H2")){
			return CodecProtocol.HTTP_2;
		}
		return CodecProtocol.init;
	}
}

package:
enum string CheckBuffer = q{
    if(buffer is null)
        buffer  = yNew!HTTPCodecBuffer();
    scope(failure) yDel(buffer);
};