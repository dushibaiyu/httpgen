module httpgen.headers;

import yu.string;
import yu.container.string;
import yu.container.vector;
import core.stdc.string;
import std.string;
import std.array;
import std.experimental.allocator.mallocator;


public import httpgen.headers.httpcommonheaders;
public import yu.tools.http1xparser.default_;

struct HTTPHeaders
{
	alias StringArray = Vector!(String,Mallocator,false);
	enum kInitialVectorReserve = 32;
	
	/**
	* Remove all instances of the given header, returning true if anything was
	* removed and false if this header didn't exist in our set.
	*/
	bool remove(ref String name)
	{
		remove(name.stdString());
	}

	bool remove(string name){
		HTTPHeaderCode code = headersHash(name);
		if(code != HTTPHeaderCode.OTHER)
			return remove(code);
		bool removed = false;
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] != HTTPHeaderCode.OTHER) continue;
			if(isSameIngnoreLowUp(name,_headersNames[i])){
				_codes[i] = HTTPHeaderCode.NONE;
				_headersNames[i] = String();
				_headerValues[i] = String();
				_deletedCount ++;
				removed = true;
			}
		}
		return removed;
	}

	bool remove(HTTPHeaderCode code){
		bool removed = false;
		HTTPHeaderCode * ptr = cast(HTTPHeaderCode *)_codes.ptr;
		const size_t len = _codes.length;
		while(true)
		{
			size_t tlen = len - (ptr - _codes.ptr);
			ptr = cast(HTTPHeaderCode *)memchr(ptr,code,tlen);
			if(ptr is null)
				break;
			tlen = ptr - codes.ptr;
			ptr ++;
			_codes[tlen] = HTTPHeaderCode.NONE;
			_headersNames[tlen] = String();
			_headerValues[tlen] = String();
			_deletedCount ++;
			removed = true;
		}
		return removed;
	}

	void add(STR)(auto ref STR name, auto ref STR value)
	in{
		assert(name.length > 0);
	}
	body{
		static if(isStdString!STR){
			HTTPHeaderCode code = headersHash(name);
		} else {
			HTTPHeaderCode code = headersHash(name.stdString());
		}
		_codes.insertBack(code);
		if(code == HTTPHeaderCode.OTHER) {
			_headersNames.append(String(HTTPHeaderCodeName[code]));
		} else {
			static if(isStdString!STR)
				_headersNames.append(String(name));
			else
				_headersNames.append(name);
		}
		static if(isStdString!STR)
				_headerValues.append(String(value));
		else
			_headerValues.append(value);

	}
	void add(STR)(HTTPHeaderCode code, auto ref STR value)
	{
		if(code == HTTPHeaderCode.OTHER || code > HTTPHeaderCode.SEC_WEBSOCKET_ACCEPT)
			return;
		_codes.insertBack(code);
		_headersNames.insertBack(String(HTTPHeaderCodeName[code]));
		static if(isStdString!STR)
				_headerValues.append(String(value));
		else
			_headerValues.append(value);
	}

	void set(STR)(auto ref STR name, auto ref STR value)
	{
		remove(name);
		add(name, value);
	}

    void set(STR)(HTTPHeaderCode code, auto ref STR value)
	{
		remove(code);
		add(code, value);
	}

	bool exists(ref String name)
	{
		exists(name.stdString);
	}

	bool exists(string name)
	{
		HTTPHeaderCode code = headersHash(name);
		if(code != HTTPHeaderCode.OTHER)
			return exists(code);
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] != HTTPHeaderCode.OTHER) continue;
			if(isSameIngnoreLowUp(name, str.stdString)){
				return true;
			}
		}
		return false;
	}

	bool exists(HTTPHeaderCode code)
	{
		return memchr(_codes.ptr,code,_codes.length) != null;
	}

	void removeAll()
	{
		_codes.clear();
		_headersNames.clear();
		_headerValues.clear();
		_deletedCount = 0;
	}

	int opApply(scope int delegate(ref String name,ref String value) opeartions)
	{
		int result = 0;
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] == HTTPHeaderCode.NONE) continue;
			result = opeartions(str, _headerValues[i]);
			if(result)
				break;
		}
		return result;
	}

	int opApply(scope int delegate(HTTPHeaderCode code,ref String name,ref String value) opeartions)
	{
		int result = 0;
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] == HTTPHeaderCode.NONE) continue;
			result = opeartions(_codes[i], str , _headerValues[i]);
			if(result)
				break;
		}
		return result;
	}

	HTTPHeaders dub()
	{
		HTTPHeaders header;
		copyTo(header);
		return header;
	}

	void copyTo(ref HTTPHeaders header)
	{
		foreach(code,ref name,ref value; this)
		{
			if(code == HTTPHeaderCode.NONE) continue;
			if(code == HTTPHeaderCode.OTHER)
				header.add(name,value);
			else
				header.add(code,value);
		}
	}
	/**
   * Get the total number of headers.
   */
	size_t size() const{
		return _codes.length - _deletedCount;
	}
	/**
   * combine all the value for this header into a string
   */
	String combine(string separator = ", ")
	{
		String str = String();
		bool frist = true;
		foreach(code,ref name,ref value; this)
		{
			if(code == HTTPHeaderCode.NONE) continue;
			if(frist) {
				str ~= value;
				frist = false;
			} else {
				str ~= separator;
				str ~= value;
			}
		}
		return str;
	}

	size_t getNumberOfValues(string name)
	{
		HTTPHeaderCode code = headersHash(name);
		if(code != HTTPHeaderCode.OTHER)
			return remove(code);
		size_t index = 0;
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] != HTTPHeaderCode.OTHER) continue;
			if(isSameIngnoreLowUp(name,str.stdString)){
				++index;
			}
		}
		return index;
	}

	size_t getNumberOfValues(HTTPHeaderCode code)
	{
		size_t index = 0;
		HTTPHeaderCode[] codes = _codes.data(false);
		HTTPHeaderCode * ptr = codes.ptr;
		const size_t len = codes.length;
		while(true)
		{
			size_t tlen = len - (ptr - codes.ptr);
			ptr = cast(HTTPHeaderCode *)memchr(ptr,code,tlen);
			if(ptr is null)
				break;
			ptr ++;
			++ index;
		}
		return index;
	}

	String getSingleOrEmpty(string  name)  {
		HTTPHeaderCode code = headersHash(name);
		if(code != HTTPHeaderCode.OTHER)
			return getSingleOrEmpty(code);
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] != HTTPHeaderCode.OTHER) continue;
			if(isSameIngnoreLowUp(name,str.stdString)){
				return _headerValues[i];
			}
		}
		return String();
	}

	String getSingleOrEmpty(HTTPHeaderCode code)  {
		HTTPHeaderCode * ptr = cast(HTTPHeaderCode *)memchr(_codes.ptr,code,_codes.length);
		if(ptr !is null){
			size_t index = ptr - codes.ptr;
			return _headerValues[index];
		}
		return String();
	}

	/**
   * Process the ordered list of values for the given header name:
   * for each value, the function/functor/lambda-expression given as the second
   * parameter will be executed. It should take one const string & parameter
   * and return bool (false to keep processing, true to stop it). Example use:
   *     hdrs.forEachValueOfHeader("someheader", [&] (const string& val) {
   *       std::cout << val;
   *       return false;
   *     });
   * This method returns true if processing was stopped (by func returning
   * true), and false otherwise.
   */
	alias LAMBDA = bool delegate(ref String value);
	bool forEachValueOfHeader(ref String name, scope LAMBDA func)
	{
		forEachValueOfHeader(name.stdString,func);
	}

	bool forEachValueOfHeader(string name,scope LAMBDA func)
	{
		HTTPHeaderCode code = headersHash(name);
		if(code != HTTPHeaderCode.OTHER)
			return forEachValueOfHeader(code,func);
		size_t index = 0;
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] != HTTPHeaderCode.OTHER) continue;
			if(isSameIngnoreLowUp(name,str.stdString)){
				if(func(_headerValues[i]))
					return true;
			}
		}
		return false;
	}

	bool forEachValueOfHeader(HTTPHeaderCode code,scope LAMBDA func)
	{
		size_t index = 0;
		HTTPHeaderCode * ptr = cast(HTTPHeaderCode *)_codes.ptr;
		const size_t len = _codes.length;
		while(true)
		{
			size_t tlen = len - (ptr - _codes.ptr);
			ptr = cast(HTTPHeaderCode *)memchr(ptr,code,tlen);
			if(ptr is null)
				break;
			tlen = ptr - codes.ptr;
			ptr ++;
			if(func(_headerValues[tlen]))
				return true;
		}
		return false;
	}
private :
	Vector!(HTTPHeaderCode) _codes ;// = Vector!(HTTPHeaderCode)(2);
	StringArray _headersNames ;
	StringArray _headerValues ;
	size_t _deletedCount = 0;
}

template isStdString(STR)
{
	enum isStdString = (is(STR == string));
}
