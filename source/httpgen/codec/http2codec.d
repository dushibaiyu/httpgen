module httpgen.codec.http2codec;

import httpgen.codec.httpcodec;
import httpgen.errocode;
import httpgen.headers;
import httpgen.httpmessage;
import httpgen.httptansaction;
import httpgen.parser;
import yu.string;
import yu.container.string;
import yu.memory.allocator;
import std.array;
import std.conv;
import std.traits;
import deimos.nghttp2;

final class HTTP2CodecBuffer : CodecBuffer
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

final class HTTP2XCodec : HTTPCodec
{
    this(TransportDirection direction, uint maxHeaderSize = (64 * 1024))
    {
        _transportDirection = direction;
        _finished = true;
        _maxHeaderSize = maxHeaderSize;
    }


private:
    nghtt
}

