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
module httpgen.codec.http1xcodec;

import httpgen.codec.httpcodec;
import httpgen.errocode;
import httpgen.headers;
import httpgen.httpmessage;
import httpgen.httptansaction;
import httpgen.parser;
import yu.string;
import yu.container.string;
import yu.tools.http1xparser;
import yu.memory.allocator;
import std.array;
import std.conv;
import std.traits;

final class HTTP1XCodecBuffer : CodecBuffer
{
    import yu.container.vector;
    import yu.exception;
    import std.experimental.allocator.mallocator;

    alias BufferData = Vector!(ubyte, Mallocator,false);

    override ubyte[] data() nothrow {
        auto dt = _data.data();
        return cast(ubyte[])dt[sended..$];
    }

    override void doFinish() nothrow {
        auto ptr = this;
        yuCathException(yDel(ptr));
    }

    override bool popSize(size_t size) nothrow {
        sended += size;
        if(sended >= _data.length)
            return true;
        else
            return false;
    }

    override void put(ubyte[] data)
    {
        _data.put(data);
    }

private:
    BufferData _data;
    uint sended = 0;
}

final class HTTP1XCodec : HTTPCodec
{
	this(TransportDirection direction, uint maxHeaderSize = (64 * 1024))
	{
		_transportDirection = direction;
		_finished = true;
		_maxHeaderSize = maxHeaderSize;
        _parser.rest(HTTPType.BOTH,_maxHeaderSize);
		_parser.onUrl(&onUrl);
		_parser.onMessageBegin(&onMessageBegin);
		_parser.onHeaderComplete(&onHeadersComplete);
		_parser.onHeaderField(&onHeaderField);
		_parser.onHeaderValue(&onHeaderValue);
		_parser.onStatus(&onStatus);
		_parser.onChunkHeader(&onChunkHeader);
		_parser.onChunkComplete(&onChunkComplete);
		_parser.onBody(&onBody);
		_parser.onMessageComplete(&onMessageComplete);
	}

	override CodecProtocol getProtocol() {
		return CodecProtocol.HTTP_1_X;
	}

	override TransportDirection getTransportDirection()
	{
		return _transportDirection;
	}

	override StreamID createStream() {
		return 0;
	}

	override bool isBusy() {
		return !_finished;
	}

	override bool shouldClose()
	{
		return !_keepalive;
	}

	override void setParserPaused(bool paused){}

	override void setCallback(CallBack callback) {
		_callback = callback;
	}

	override size_t onIngress(ubyte[] buf)
	{
		trace("on Ingress!!");
		if(_finished) {
			_parser.rest(HTTPType.BOTH,_maxHeaderSize);
		}
		auto size = _parser.httpParserExecute(buf);
		if(size != buf.length && _parser.isUpgrade == false && _callback){
				_callback.onError(0,HTTPErrorCode.PROTOCOL_ERROR);
		}
		return cast(size_t) size;
	}

	override void onTimeOut()
	{
	}

	override void detach(StreamID id)
	{
	}

    CodecBuffer generateHeader(
        StreamID id,
        HTTPMessage msg,
        StreamID assocStream = 0,
        bool eom = false)
	{
        HTTP1XCodecBuffer buffer  = yNew!HTTP1XCodecBuffer();
        scope(failure) yDel(buffer);

		const bool upstream = (_transportDirection == TransportDirection.UPSTREAM);
		const size_t beforLen = buffer.length;
		auto hversion = msg.getHTTPVersion();
		_egressChunked = msg.chunked && !_egressUpgrade;
		_lastChunkWritten = false;
		bool hasTransferEncodingChunked = false;
		bool hasUpgradeHeader = false;
		bool hasDateHeader = false;
		bool is1xxResponse = false;
		bool ingorebody = false;
		_keepalive = _keepalive & msg.wantsKeepAlive;
		if(!upstream) {
			is1xxResponse = msg.is1xxResponse;
			appendLiteral(buffer,"HTTP/");
			appendLiteral(buffer,to!string(hversion.maj));
			appendLiteral(buffer,".");
			appendLiteral(buffer,to!string(hversion.min));
			appendLiteral(buffer," ");
			ushort code = msg.statusCode;
			ingorebody = responseBodyMustBeEmpty(code);
			appendLiteral(buffer,to!string(code));
			appendLiteral(buffer," ");
			appendLiteral(buffer,msg.statusMessage);
		} else {
			appendLiteral(buffer,msg.methodString);
			appendLiteral(buffer," ");
			appendLiteral(buffer,msg.getPath);
			appendLiteral(buffer," HTTP/");
			appendLiteral(buffer,to!string(hversion.maj));
			appendLiteral(buffer,".");
			appendLiteral(buffer,to!string(hversion.min));
			_mayChunkEgress = (hversion.maj == 1) && (hversion.min >= 1);
		}
		appendLiteral(buffer,"\r\n");
		_egressChunked &= _mayChunkEgress;
		string contLen;
		string upgradeHeader;
		foreach(HTTPHeaderCode code,string key,string value; msg.getHeaders)
		{
			if(code == HTTPHeaderCode.CONTENT_LENGTH){
				contLen = value;
				continue;
			} else if (code ==  HTTPHeaderCode.CONNECTION) {
				if(isSameIngnoreLowUp(value,"close")) {
					_keepalive = false;
				}
				continue;
			} else if(code == HTTPHeaderCode.UPGRADE){
				if(upstream) upgradeHeader = value;
				hasUpgradeHeader = true;
			}  else if (!hasTransferEncodingChunked &&
				code == HTTPHeaderCode.TRANSFER_ENCODING) {
				if(!isSameIngnoreLowUp(value,"chunked")) 
					continue;
				hasTransferEncodingChunked = true;
				if(!_mayChunkEgress) 
					continue;
			} 
			appendLiteral(buffer,key);
			appendLiteral(buffer,": ");
			appendLiteral(buffer,value);
			appendLiteral(buffer,"\r\n");
		}
		_inChunk = false;
		bool bodyCheck = ((!upstream) && _keepalive && !ingorebody  && !_egressUpgrade) ||
				// auto chunk POSTs and any request that came to us chunked
				(upstream && ((msg.method == HTTPMethod.HTTP_POST) || _egressChunked));
		// TODO: 400 a 1.0 POST with no content-length
		// clear egressChunked_ if the header wasn't actually set
		_egressChunked &= hasTransferEncodingChunked;
		if(bodyCheck && contLen.length == 0 && !_egressChunked){
			if (!hasTransferEncodingChunked && _mayChunkEgress) {
				appendLiteral(buffer,"Transfer-Encoding: chunked\r\n");
				_egressChunked = true;
			} else {
				_keepalive = false;
			}
		}
		if(!is1xxResponse || upstream || hasUpgradeHeader){
			appendLiteral(buffer,"Connection: ");
			if(hasUpgradeHeader) {
				appendLiteral(buffer,"upgrade\r\n");
				_keepalive = true;
			} else if(_keepalive)
				appendLiteral(buffer,"keep-alive\r\n");
			else
				appendLiteral(buffer,"close\r\n");
		}
		appendLiteral(buffer,"Server: Collie\r\n");
		if(contLen.length > 0){
			appendLiteral(buffer,"Content-Length: ");
			appendLiteral(buffer,contLen);
			appendLiteral(buffer,"\r\n");
		}

		appendLiteral(buffer,"\r\n");
		return buffer;
	}

    override CodecBuffer generateBody(StreamID id,
        const ubyte[] data,CodecBuffer buffer,
        bool eom)
	{
        mixin(CheckBuffer);
        appendLiteral(buffer,data);
		if(_egressChunked && _inChunk) {
            appendLiteral(buffer,"\r\n");
			_inChunk = false;
		}
		if(eom)
            buffer = generateEOM(id,buffer);
        return buffer;
	}

    override CodecBuffer generateChunkHeader(
        StreamID id,
        size_t length,CodecBuffer buffer = null)
	{
		trace("_egressChunked  ", _egressChunked);
		if (_egressChunked){
			import std.format;
			_inChunk = true;
            mixin(CheckBuffer);
            scope void put(char str)
            {
                char * ptr = &str;
                appendLiteral(buffer,ptr[0..1]);
            }
            formattedWrite(&put,"%x\r\n",length);
		}
		return buffer;
	}


    override CodecBuffer generateChunkTerminator(
        StreamID id,CodecBuffer buffer = null)
	{
		if(_egressChunked && _inChunk)
		{
            mixin(CheckBuffer);
			_inChunk = false;
			appendLiteral(buffer,"\r\n");
		}
		return buffer;
	}

    override generateEOM(StreamID id,CodecBuffer buffer = null)
	{
		size_t rlen = 0;
		if(_egressChunked) {
			assert(!_inChunk);
			if (_headRequest && _transportDirection == TransportDirection.DOWNSTREAM) {
				_lastChunkWritten = true;
			} else {
                mixin(CheckBuffer);
				if (!_lastChunkWritten) {
					_lastChunkWritten = true;
					appendLiteral(buffer,"0\r\n");
				}
				appendLiteral(buffer,"\r\n");
			}
		}
		switch (_transportDirection) {
			case TransportDirection.DOWNSTREAM:
				_responsePending = false;
				break;
			case TransportDirection.UPSTREAM:
				_requestPending = false;
				break;
			default:
				break;
		}
        return buffer;
	}

protected:

    final void appendLiteral(T)(HTTP1XCodecBuffer buffer, T[] data) if(isSomeChar!(Unqual!T) || is(Unqual!T == byte) || is(Unqual!T == ubyte))
	{
		buffer.put(cast(ubyte[])data);
	}

	void onMessageBegin(ref HTTP1xParser){
		_finished = false;
		_headersComplete = false;
		_message = yNew!HTTPMessage();
		if (_transportDirection == TransportDirection.DOWNSTREAM) {
			_requestPending = true;
			_responsePending = true;
		}
		// If there was a 1xx on this connection, don't increment the ingress txn id
		if (_transportDirection == TransportDirection.DOWNSTREAM ||
			!_is1xxResponse) {
		}
		if (_transportDirection == TransportDirection.UPSTREAM) {
			_is1xxResponse = false;
		}
        _transaction = yNew!HTTPTransaction(_transportDirection,0,0);
		if(_callback)
			_callback.onMessageBegin(_transaction, _message);
		_currtKey.clear();
		_currtValue.clear();
	}
	
	void onHeadersComplete(ref HTTP1xParser parser){
		_mayChunkEgress = ((parser.major == 1) && (parser.minor >= 1));
		_message.setHTTPVersion(cast(ubyte)parser.major, cast(ubyte)parser.minor);
		_egressUpgrade = parser.isUpgrade;
		_message.upgraded(parser.isUpgrade);
		int klive = parser.keepalive;
		trace("++++++++++klive : ", klive);
		switch(klive){
			case 1:
				_keepalive = true;
				break;
			case 2:
				_keepalive = false;
				break;
			default :
				_keepalive = false;
		}
		_message.wantsKeepAlive(_keepalive);
		_headersComplete = true;
		if(_message.upgraded){
			string upstring  = _message.getHeaders.getSingleOrEmpty(HTTPHeaderCode.UPGRADE);
			CodecProtocol pro = getProtocolFormString(upstring);
			if(_callback)
				_callback.onNativeProtocolUpgrade(_transaction,pro,upstring,_message);
		} else {
			if(_callback)
				_callback.onHeadersComplete(_transaction,_message);
		}
	}
	
	void onMessageComplete(ref HTTP1xParser parser){
		_finished = true;
		switch (_transportDirection) {
			case TransportDirection.DOWNSTREAM:
			{
				_requestPending = false;
				// else there was no match, OR we upgraded to http/1.1 OR someone specified
				// a non-native protocol in the setAllowedUpgradeProtocols.  No-ops
				break;
			}
			case TransportDirection.UPSTREAM:
				_responsePending = _is1xxResponse;
				break;
			default: break;
		}
		if(_callback)
			_callback.onMessageComplete(_transaction,parser.isUpgrade);
	}
	
	void onChunkHeader(ref HTTP1xParser parser){
		if(_callback)
			_callback.onChunkHeader(_transaction,cast(size_t)parser.contentLength);
	}
	
	void onChunkComplete(ref HTTP1xParser parser){
		if(_callback)
			_callback.onChunkComplete(_transaction);
	}
	
	void onUrl(ref HTTP1xParser parser, ubyte[] data, bool finish)
	{
		//trace("on Url");
		_message.method = parser.methodCode();
		_connectRequest = (parser.methodCode() == HTTPMethod.HTTP_CONNECT);
		
		// If this is a headers-only request, we shouldn't send
		// an entity-body in the response.
		_headRequest = (parser.methodCode() == HTTPMethod.HTTP_HEAD);

		_currtKey.insertBack(data);
		if(finish) {
			ubyte[] tdata = _currtKey.data(true);
			_message.url = cast(string)tdata;
		}
	}
	
	void onStatus(ref HTTP1xParser parser, ubyte[] data, bool finish)
	{

		_currtKey.insertBack(data);
		if(finish) {
			string sdata = cast(string)_currtKey.data(true);
			_message.statusCode(cast(ushort)parser.statusCode);
			_message.statusMessage(sdata);
		}
	}
	
	void onHeaderField(ref HTTP1xParser parser, ubyte[] data, bool finish)
	{
		//trace("on onHeaderField");
		_currtKey.insertBack(data);
	}
	
	void onHeaderValue(ref HTTP1xParser parser, ubyte[] data, bool finish)
	{
	//	trace("on onHeaderField");
		_currtValue.insertBack(data);
		if(finish){
			string key = cast(string)_currtKey.data(true);
			string value = cast(string)_currtValue.data(true);
			trace("http header: \t", key, " : ", value);
			_message.getHeaders.add(key,value);
		}
	}
	
	void onBody(ref HTTP1xParser parser, ubyte[] data, bool finish)
	{
		trace("on boday, length : ", data.length);
		_callback.onBody(_transaction,data);
	}

	bool responseBodyMustBeEmpty(ushort status) {
		return (status == 304 || status == 204 ||
			(100 <= status && status < 200));
	}
private:
	TransportDirection _transportDirection;
	CallBack _callback;
	HTTPMessage _message;
	String _currtKey;
    String _currtValue;
    HTTP1xParser _parser;

	uint _maxHeaderSize;
	bool _finished;
private:
	bool _parserActive = false;
	bool _pendingEOF = false;
	bool _parserPaused = false;
	bool _parserError = false;
	bool _requestPending = false;
	bool _responsePending = false;
	bool _egressChunked = false;
	bool _inChunk = false;
	bool _lastChunkWritten = false;
	bool _keepalive = false;
	bool _disableKeepalivePending = false;
	bool _connectRequest = false;
	bool _headRequest = false;
	bool _expectNoResponseBody = false;
	bool _mayChunkEgress = false;
	bool _is1xxResponse = false;
	bool _inRecvLastChunk = false;
	bool _ingressUpgrade = false;
	bool _ingressUpgradeComplete = false;
	bool _egressUpgrade = false;
	bool _nativeUpgrade = false;
	bool _headersComplete = false;
}

private :
enum string CheckBuffer = q{
    if(buffer is null)
        buffer  = yNew!HTTP1XCodecBuffer();
    scope(failure) yDel(buffer);
};