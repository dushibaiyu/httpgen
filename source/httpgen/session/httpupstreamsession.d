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
module httpgen.session.httpupstreamsession;

import std.exception;

import httpgen.session.httpsession;
import httpgen.headers;
import httpgen.codec.wsframe;
import httpgen.httpmessage;
import httpgen.httptansaction;
import httpgen.codec.httpcodec;
import std.base64;
import std.digest.sha;
import httpgen.codec.websocketcodec;

final class HTTPDownstreamSession : HTTPSession
{
	this(HTTPSessionController controller,HTTPCodec codec, SessionDown down)
	{
		super(controller,codec,down);
	}
	
protected:
	override void setupOnHeadersComplete(ref HTTPTransaction txn,
		HTTPMessage msg)
	{
		auto handle =  _controller.getRequestHandler(txn,msg);
		errnoEnforce(handle,"handle is null !");
		txn.handler(handle);
		txn.onIngressHeadersComplete(msg);

	}
	
	override void setupProtocolUpgrade(ref HTTPTransaction txn,CodecProtocol protocol,string protocolString,HTTPMessage msg) {
		//restCodeC(new WebsocketCodec(TransportDirection.UPSTREAM));
	}
}
