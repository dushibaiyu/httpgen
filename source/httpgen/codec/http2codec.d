module httpgen.codec.http2codec;

import httpgen.codec.httpcodec;
import httpgen.errocode;
import httpgen.headers;
import httpgen.httpmessage;
import httpgen.httptansaction;
import yu.string;
import yu.container.string;
import containers.dynamicarray;
import yu.memory.allocator;
import std.experimental.allocator.mallocator;
import std.array;
import std.conv;
import std.traits;
import deimos.nghttp2;
import yu.memory.smartref;
import yu.memory.allocator;
import std.exception;
import containers.hashmap;
import containers.internal.hash;

enum Method_ = ":method";
enum Seheme_ = ":scheme";
enum Path_ = ":path";
enum Status_ = ":status";


class Http2CodecEcxeption : Exception
{
    mixin basicExceptionCtors;
}

final class HTTP2XCodec : HTTPCodec
{ 
    alias HeadersMap = HashMap!(StreamID,HTTPMessage,YuAlloctor,generateHash!StreamID,false);
    alias SendBuffer = void delegate(HTTPCodecBuffer);
    alias NgHttp2NvArray = DynamicArray!(nghttp2_nv,Mallocator,false);

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

    override void setCallback(CallBack callback) {
        _callback = callback;
    }

    override size_t onIngress(ubyte[] buf)
    {
        trace("on Ingress!!");
        nghttp2_session * session = http2session();
        if(!session) return 0;
        auto readlen = nghttp2_session_mem_recv(session, buf.ptr,buf.length);
        if(readlen < 0)
            return 0;
        if(nghttp2_session_send(session) != 0)
            return 0;
        return cast(size_t)readlen;
    }

    override bool shouldClose() {
        nghttp2_session * session = http2session();
        if(!session) return true;
        return !nghttp2_session_want_read(session) &&
            !nghttp2_session_want_write(session);
    }
   

    bool isUpStream(){
        return (_transportDirection == TransportDirection.UPSTREAM);
    }

    override HTTPCodecBuffer generateHeader(
        StreamID id,
        scope HTTPMessage msg,
        StreamID assocStream = 0,
        bool eom = false)
    {
        char[10] statusBuffer;
        char[] status;
        NgHttp2NvArray attay = NgHttp2NvArray();
        if(isUpStream && !msg.isPushPromise){
            import core.internal.string;
            status = unsignedToTempString(msg.statusCode,statusBuffer[],10);
            attay ~= buildNghttp2NV(Status_, status, nghttp2_nv_flag.NGHTTP2_NV_FLAG_NO_COPY_VALUE);
        } else {
            attay ~= buildNghttp2NV(Method_, msg.methodString,nghttp2_nv_flag.NGHTTP2_NV_FLAG_NO_COPY_VALUE);
            attay ~= buildNghttp2NV(Seheme_, msg.url.scheme.stdString,nghttp2_nv_flag.NGHTTP2_NV_FLAG_NO_COPY_VALUE);
            attay ~= buildNghttp2NV(Path_, msg.url.path.stdString,nghttp2_nv_flag.NGHTTP2_NV_FLAG_NO_COPY_VALUE);
        }
        foreach(key,value; msg.getHeaders){
            attay ~= buildNghttp2NV(key.stdString, value.stdString,nghttp2_nv_flag.NGHTTP2_NV_FLAG_NO_COPY_NAME | nghttp2_nv_flag.NGHTTP2_NV_FLAG_NO_COPY_VALUE);
        }
        int flags = nghttp2_flag.NGHTTP2_FLAG_END_HEADERS;
        if(eom)
            flags |= nghttp2_flag.NGHTTP2_FLAG_END_STREAM;
        nghttp2_submit_headers(http2session(),cast(ubyte)flags,id,null,attay.ptr,attay.length,null);
        return null;
    }
    
    override HTTPCodecBuffer generateBody(StreamID id,
        in ubyte[] data,HTTPCodecBuffer buffer,
        bool eom)
    {
        Http2ReadBuffer sbuf = Http2ReadBuffer(cast(ubyte[])data);
        int flags = nghttp2_flag.NGHTTP2_FLAG_NONE;
        if(eom)
            flags |= nghttp2_flag.NGHTTP2_FLAG_END_STREAM;
        nghttp2_data_provider source;
        source.source.ptr = &sbuf;
        source.read_callback = &readSend;
        nghttp2_submit_data(http2session(), cast(ubyte)flags,cast(int)id,&source);
        return null;
    }
    
    override HTTPCodecBuffer generateEOM(StreamID id,HTTPCodecBuffer buffer = null)
    {
        Http2ReadBuffer sbuf = Http2ReadBuffer();
        int flags = nghttp2_flag.NGHTTP2_FLAG_END_STREAM;
        nghttp2_data_provider source;
        source.source.ptr = &sbuf;
        source.read_callback = &readSend;
        nghttp2_submit_data(http2session(), cast(ubyte)flags,cast(int)id,&source);
        return null;
    }


private:
    void initSession()
    {
        nghttp2_session_callbacks * callbacks;
        int rv = nghttp2_session_callbacks_new(&callbacks);
        enforce!Http2CodecEcxeption((rv == 0), "nghttp2 create callback error! ");
        _sessionCallback.reset(callbacks);
        nghttp2_session_callbacks_set_send_callback(callbacks, &sendCallback);
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
//        nghttp2_session_callbacks_set_on_frame_send_callback(callbacks,
//            &onFrameSendCallback);
//        nghttp2_session_callbacks_set_on_frame_not_send_callback(
//            callbacks, &onFrameNotSendCallback);
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

    void closeStream(StreamID id, uint error_code)
    {
        HTTPMessage msg = _headers.get(id,null);
        if(!msg)yDel(msg);
        if(_callback)
            _callback.onError(id, cast(HTTPErrorCode)error_code);
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

struct Http2ReadBuffer
{
    this(ubyte[] dt)
    {
        data = dt;
    }
    size_t read(ubyte * buf, size_t len)
    {
        import core.stdc.string : memcpy;
        if(data.length == 0) return 0;
        size_t rlen;
        if(len >= data.length){
            rlen = data.length;
            memcpy(buf,data.ptr,rlen);
            data = null;
        } else {
            rlen = len;
            memcpy(buf,data.ptr,rlen);
            data = data[len..$];
        }
        return rlen;
    }
    
private:
    ubyte[] data;
}

extern(C):
@system:
int onBeginHeadersCallback(nghttp2_session *session, const(nghttp2_frame) *frame, void *user_data) {
 
    
    if (frame.hd.type != nghttp2_frame_type.NGHTTP2_HEADERS ||
        frame.headers.cat != nghttp2_headers_category.NGHTTP2_HCAT_REQUEST || frame.hd.type != NGHTTP2_PUSH_PROMISE) {
        return 0;
    }
    auto stream_id = 0;
    if(frame.hd.type == nghttp2_frame_type.NGHTTP2_HEADERS)
        stream_id = frame.hd.stream_id;
    else
        stream_id = frame.push_promise.promised_stream_id;

    auto handler = cast(HTTP2XCodec)(user_data);
    handler.newStream(stream_id);

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
        //case ":authority" :
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
    auto stream_id = 0;
    if(frame.hd.type == nghttp2_frame_type.NGHTTP2_HEADERS)
        stream_id = frame.hd.stream_id;
    else
        stream_id = frame.push_promise.promised_stream_id;
    auto handler = cast(HTTP2XCodec)(user_data);
  
    switch (frame.hd.type) with (nghttp2_frame_type){
        case NGHTTP2_DATA:           
            if (frame.hd.flags & NGHTTP2_FLAG_END_STREAM) {
                if(handler._callback)
                    handler._callback.onMessageComplete(stream_id,false);
            }
           break;
        case NGHTTP2_HEADERS: {
            if (frame.headers.cat != NGHTTP2_HCAT_REQUEST) {
                break;
            }
            if(!handler._callback)
                break;

            handler._callback.onHeadersComplete(stream_id, handler._headers.get(stream_id,null));
            
            if (frame.hd.flags & NGHTTP2_FLAG_END_STREAM) 
                handler._callback.onMessageComplete(stream_id,false);

            break;
        }
    }
    
    return 0;
}

int onDataChunkRecvCallback(nghttp2_session *session, ubyte flags,
    int stream_id, const(ubyte) *data,
    size_t len, void *user_data) {
    auto handler = cast(HTTP2XCodec)(user_data);
    if(handler._callback)
        handler._callback.onBody(cast(HTTP2XCodec.StreamID)stream_id,data[0..len]);  
    return 0;
}

int onStreamCloseCallback(nghttp2_session *session, int stream_id,
    uint error_code, void *user_data) {
    auto handler = cast(HTTP2XCodec)(user_data);
    handler.closeStream(cast(HTTP2XCodec.StreamID)stream_id, error_code);  
    return 0;
}

ssize_t sendCallback(nghttp2_session *session, const (ubyte) *data,
    size_t length, int flags, void *user_data) {
    auto handler = cast(HTTP2XCodec)(user_data);
    if(length > 0 && handler._sendFun){
        HTTPCodecBuffer buffer = yNew!HTTPCodecBuffer();
        buffer.put(data[0..length]);
        handler._sendFun(buffer);
    }
    return cast(ssize_t)length;
}

auto buildNghttp2NV(const(char)[] key, const(char)[] v, int flags = 0)
{
    nghttp2_nv nv;
    nv.name = cast(ubyte *)key.ptr;
    nv.namelen = key.length;
    nv.value = cast(ubyte *) v.ptr;
    nv.valuelen = v.length;
    nv.flags = cast(ubyte)flags;
    return nv;
}

import core.stdc.config;

c_long readSend(nghttp2_session* session, int stream_id, ubyte* buf, size_t length, uint* data_flags, nghttp2_data_source* source, void* user_data)
{
    Http2ReadBuffer * buf = cast(Http2ReadBuffer *)(source.ptr);
    return cast(c_long)buf.read(buf,length);
}