﻿module httpgen.codec.http2codec;

import httpgen.codec.httpcodec;
import httpgen.errocode;
import httpgen.headers;
import httpgen.httpmessage;
import httpgen.httptansaction;
import yu.string;
import yu.container.string;
import yu.memory.allocator;
import std.array;
import std.conv;
import std.traits;
import deimos.nghttp2;
import yu.memory.smartref;
import yu.memory.allocator;
import std.exception;
import containers.hashmap;
import containers.internal.hash;

class Http2CodecEcxeption : Exception
{
    mixin basicExceptionCtors;
}

final class HTTP2XCodec : HTTPCodec
{ 
    alias HeadersMap = HashMap!(StreamID,HTTPMessage,IAllocator,generateHash!StreamID,false);
    alias SendBuffer = void delegate(HTTPCodecBuffer);

    this(TransportDirection direction,SendBuffer send, uint maxFrmesize = (64 * 1024))
    {
        _headers = HeadersMap(yuAlloctor);
        _transportDirection = direction;
        _finished = true;
        _sendFun = send;
        _session.resetDeleter(&freeSession);
        _sessionCallback.resetDeleter(&freeCallBack);
        initSession();
        nghttp2_settings_entry ent;
        ent.settings_id = nghttp2_settings_id.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS; ent.value  = 100; // set max 100
        nghttp2_submit_settings(http2session(), nghttp2_flag.NGHTTP2_FLAG_NONE, &ent, 1);
        ent.settings_id = nghttp2_settings_id.NGHTTP2_SETTINGS_MAX_FRAME_SIZE;
        ent.value = maxFrmesize;
        nghttp2_submit_settings(http2session(), nghttp2_flag.NGHTTP2_FLAG_NONE, &ent, 1);
    }

    ~this(){
        foreach(const StreamID id, HTTPMessage msg; _headers){
            if(msg is null) continue;
            yDel(msg);
            msg = null;
        }
    }

    override void setParserPaused(bool paused){}
    
    override void setCallback(CallBack callback) {
        _callback = callback;
    }


    bool isUpStream(){
        return (_transportDirection == TransportDirection.UPSTREAM);
    }
private:
    void initSession()
    {
        nghttp2_session_callbacks * callbacks;
        int rv = nghttp2_session_callbacks_new(&callbacks);
        enforce!Http2CodecEcxeption((rv == 0), "nghttp2 create callback error! ");
        _sessionCallback.reset(callbacks);
        nghttp2_session_callbacks_set_send_callback(callbacks, &send_callback);
        nghttp2_session_callbacks_set_on_begin_headers_callback(
            callbacks, &onBeginHeadersCallback);
        nghttp2_session_callbacks_set_on_header_callback(callbacks,
            &onHeaderCallback);
        nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks,
            &onFrameRecvCallback);
        nghttp2_session_callbacks_set_on_data_chunk_recv_callback(
            callbacks, &onDataChunkRecvCallback);
        nghttp2_session_callbacks_set_on_stream_close_callback(
            callbacks, &onStreamCloseCallback);
        nghttp2_session_callbacks_set_on_frame_send_callback(callbacks,
            &onFrameSendCallback);
        nghttp2_session_callbacks_set_on_frame_not_send_callback(
            callbacks, &onFrameNotSendCallback);
        nghttp2_session * session;
        if(isUpStream())
            rv = nghttp2_session_client_new(&session, callbacks, cast(void*)this);
        else
            rv = nghttp2_session_server_new(&session, callbacks, cast(void*)this);
        enforce!Http2CodecEcxeption((rv == 0), "nghttp2 create Session error! ");
        _session.reset(session);
    }

    nghttp2_session * http2session(){
        if(_session.isNull) return null;
        return cast(nghttp2_session *)_session.data();
    }

    void newStream(StreamID id)
    {
        HTTPMessage msg = yNew!HTTPMessage();
        _headers[id] = msg;
        if(_callback)
            _callback.onMessageBegin(id, msg);
    }

private:
    CallBack _callback;
    //ScopedRef!nghttp2_session _session;
    ScopedRef!void _session;
    ScopedRef!void _sessionCallback;
    //ScopedRef!nghttp2_session_callbacks _sessionCallback;
    HeadersMap _headers;
    TransportDirection _transportDirection;
    SendBuffer _sendFun;
    bool _finished;
}

private :
void freeSession(ref typeof(SmartGCAllocator.instance) , void * session)//nghttp2_session * session)
{
    nghttp2_session_del(cast(nghttp2_session *)session);
}

void freeCallBack(ref typeof(SmartGCAllocator.instance) , void * callBack)// nghttp2_session_callbacks * callBack)
{
    nghttp2_session_callbacks_del(cast(nghttp2_session_callbacks *)callBack);
}

extern(C):
@system:
int onBeginHeadersCallback(nghttp2_session *session, const(nghttp2_frame) *frame, void *user_data) {
 
    
    if (frame.hd.type != nghttp2_frame_type.NGHTTP2_HEADERS ||
        frame.headers.cat != nghttp2_headers_category.NGHTTP2_HCAT_REQUEST) {
        return 0;
    }
    auto handler = cast(HTTP2XCodec)(user_data);
    handler.newStream(frame.hd.stream_id);
    
    return 0;
}

int onHeaderCallback(nghttp2_session *session, const(nghttp2_frame) *frame, const(ubyte) *name, size_t namelen,
    const(ubyte) *value, size_t valuelen, ubyte flags,
    void *user_data) {
    if (frame.hd.type != nghttp2_frame_type.NGHTTP2_HEADERS && frame.hd.type != nghttp2_frame_type.NGHTTP2_PUSH_PROMISE) {
        return 0;
    }
    import yu.tools.http1xparser.default_;

    auto stream_id = 0;
    if(frame.hd.type == nghttp2_frame_type.NGHTTP2_HEADERS)
        stream_id = frame.hd.stream_id;
    else
        stream_id = frame.push_promise.promised_stream_id;
   
    auto handler = cast(HTTP2XCodec)(user_data);
    HTTPMessage header = handler._headers.get(stream_id,null);
    if (header is null) return 0;
    string key = cast(string)(name[0..namelen]);
    string val = cast(string)(value[0..valuelen]);
    switch(key)
    {
        case ":method":
            header.method(method_id.get(val,HTTPMethod.INVAILD));
        break;
        case ":scheme":
            header.url.scheme = val;
            break;
        case ":host":
            header.url.host = val;
            header.getHeaders.add("host",val);
            break;
        case ":path":
            header.setUrl(val);
            break;
        case ":status":{
                ushort code = to!ushort(val);
                header.statusCode(code);
        }
            break;
        default:
            if(key[0] == ':')
                key = key[1..$];
            header.getHeaders.add(key,val);
            break;
    }
    return 0;
}

int onFrameRecvCallback(nghttp2_session *session, const(nghttp2_frame) *frame,
    void *user_data) {
    auto handler = cast(HTTP2XCodec)(user_data);
//
//    auto strm = handler.find_stream(frame.hd.stream_id);
//    
//    switch (frame.hd.type) {
//        case NGHTTP2_DATA:
//            if (!strm) {
//                break;
//            }
//            
//            if (frame.hd.flags & NGHTTP2_FLAG_END_STREAM) {
//                strm.request().impl().call_on_data(nullptr, 0);
//            }
//            
//            break;
//        case NGHTTP2_HEADERS: {
//            if (!strm || frame.headers.cat != NGHTTP2_HCAT_REQUEST) {
//                break;
//            }
//            
//            auto &req = strm.request().impl();
//            req.remote_endpoint(handler.remote_endpoint());
//            
//            handler.call_on_request(*strm);
//            
//            if (frame.hd.flags & NGHTTP2_FLAG_END_STREAM) {
//                strm.request().impl().call_on_data(nullptr, 0);
//            }
//            
//            break;
//        }
//    }
    
    return 0;
}

int onDataChunkRecvCallback(nghttp2_session *session, ubyte flags,
    int stream_id, const(ubyte) *data,
    size_t len, void *user_data) {
//    auto handler = static_cast<http2_handler *>(user_data);
//    auto strm = handler.find_stream(stream_id);
//    
//    if (!strm) {
//        return 0;
//    }
//    
//    strm.request().impl().call_on_data(data, len);
//    
    return 0;
}

int onStreamCloseCallback(nghttp2_session *session, int stream_id,
    uint error_code, void *user_data) {
//    auto handler = static_cast<http2_handler *>(user_data);
//    
//    auto strm = handler.find_stream(stream_id);
//    if (!strm) {
//        return 0;
//    }
//    
//    strm.response().impl().call_on_close(error_code);
//    
//    handler.close_stream(stream_id);
//    
    return 0;
}

int onFrameSendCallback(nghttp2_session *session, const(nghttp2_frame) *frame,
    void *user_data) {
//    auto handler = static_cast<http2_handler *>(user_data);
//    
//    if (frame.hd.type != NGHTTP2_PUSH_PROMISE) {
//        return 0;
//    }
//    
//    auto strm = handler.find_stream(frame.push_promise.promised_stream_id);
//    
//    if (!strm) {
//        return 0;
//    }
//    
//    auto &res = strm.response().impl();
//    res.push_promise_sent();
    
    return 0;
}

int onFrameNotSendCallback(nghttp2_session *session,
    const(nghttp2_frame) *frame, int lib_error_code,
    void *user_data) {
//    if (frame.hd.type != NGHTTP2_HEADERS) {
//        return 0;
//    }
//    
//    // Issue RST_STREAM so that stream does not hang around.
//    nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, frame.hd.stream_id,
//        NGHTTP2_INTERNAL_ERROR);
    
    return 0;
}

ssize_t send_callback(nghttp2_session *session, const (ubyte) *data,
    size_t length, int flags, void *user_data) {
    auto handler = cast(HTTP2XCodec)(user_data);
    if(length > 0 && handler._sendFun){
        HTTPCodecBuffer buffer = yNew!HTTPCodecBuffer();
        buffer.put(data[0..length]);
    }
    //TODO: send
    return cast(ssize_t)length;
}