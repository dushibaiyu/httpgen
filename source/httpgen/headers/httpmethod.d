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
module httpgen.headers.httpmethod;

enum HTTPMethod : ushort
{
	DELETE = 0,
	GET = 1,
	HEAD = 2,
	POST = 3,
	PUT = 4,
	/* pathological */
	CONNECT = 5,
	OPTIONS = 6,
	TRACE = 7,
	/* WebDAV */
	COPY = 8,
	LOCK = 9,
	MKCOL = 10,
	MOVE = 11,
	PROPFIND = 12,
	PROPPATCH = 13,
	SEARCH = 14,
	UNLOCK = 15,
	BIND = 16,
	REBIND = 17,
	UNBIND = 18,
	ACL = 19,
	/* subversion */
	REPORT = 20,
	MKACTIVITY = 21,
	CHECKOUT = 22,
	MERGE = 23,
	/* upnp */
	MSEARCH = 24,
	NOTIFY = 25,
	SUBSCRIBE = 26,
	UNSUBSCRIBE = 27,
	/* RFC-5789 */
	PATCH = 28,
	PURGE = 29,
	/* CalDAV */
	MKCALENDAR = 30,
	/* RFC-2068, section 19.6.1.2 */
	LINK = 31,
	UNLINK = 32,
	INVAILD = 33
}

enum string[34] httpMethodStrings = [
	"DELETE", "GET", "HEAD", "POST", "PUT", 
	/* pathological */
	"CONNECT", "OPTIONS", "TRACE",
	/* WebDAV */
	"COPY", "LOCK", "MKCOL", "MOVE", "PROPFIND", "PROPPATCH", "SEARCH",
	"UNLOCK", "BIND", "REBIND", "UNBIND", "ACL", 
	/* subversion */
	"REPORT", "MKACTIVITY",
	"CHECKOUT", "MERGE", 
	/* upnp */
	"MSEARCH", "NOTIFY", "SUBSCRIBE", "UNSUBSCRIBE", 
	/* RFC-5789 */
	"PATCH", "PURGE", 
	/* CalDAV */
	"MKCALENDAR", 
	/* RFC-2068, section 19.6.1.2 */
	"LINK", "UNLINK", 
	/* 无效的 */
	"INVAILD" 
];