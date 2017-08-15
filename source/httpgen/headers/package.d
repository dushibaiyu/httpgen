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
    alias CodeArray = Vector!(HTTPHeaderCode,Mallocator,false);
	enum kInitialVectorReserve = 32;
	
	/**
	* Remove all instances of the given header, returning true if anything was
	* removed and false if this header didn't exist in our set.
	*/
	bool remove(STR)(STR value){
        string name = cast(string)value;
		HTTPHeaderCode code = headersHash(name);
		if(code != HTTPHeaderCode.OTHER)
			return remove(code);
		bool removed = false;
		foreach(size_t i, ref String str; _headersNames){
			if(_codes[i] != HTTPHeaderCode.OTHER) continue;
			if(isSameIngnoreLowUp(name,_headersNames[i].stdString)){
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
			tlen = ptr - _codes.ptr;
			ptr ++;
			_codes[tlen] = HTTPHeaderCode.NONE;
			_headersNames[tlen] = String();
			_headerValues[tlen] = String();
			_deletedCount ++;
			removed = true;
		}
		return removed;
	}

	void add(STR)(auto ref STR key, auto ref STR value)
	in{
		assert(name.length > 0);
	}
	body{
        string name = cast(string)key;
		HTTPHeaderCode code = headersHash(name);
		_codes.insertBack(code);
		if(code == HTTPHeaderCode.OTHER) {
			_headersNames.append(String(HTTPHeaderCodeName[code]));
		} else {
            static if(isYuString!STR)
                _headersNames.append(key);
			else
				_headersNames.append(String(name));
		}
        string tvalue = cast(string)value;
        static if(isYuString!STR)
            _headerValues.append(value);
		else
            _headerValues.append(String(tvalue));

	}
	void add(STR)(HTTPHeaderCode code, auto ref STR value)
	{
		if(code == HTTPHeaderCode.OTHER || code > HTTPHeaderCode.SEC_WEBSOCKET_ACCEPT)
			return;
		_codes.insertBack(code);
		_headersNames.insertBack(String(HTTPHeaderCodeName[code]));
		static if(isYuString!STR)
            _headerValues.append(value);
        else{
            string tvalue = cast(string)value;
            _headerValues.append(String(tvalue));
        }
			
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

    bool exists(STR)(STR key)
	{
        string name = cast(string)key;
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

	int opApply(scope int delegate(String name,String value) opeartions)
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

	int opApply(scope int delegate(HTTPHeaderCode code,String name,String value) opeartions)
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
		foreach(code,name,value; this)
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
		foreach(code,name,value; this)
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
        auto ptr = _codes.ptr;
        const size_t len = _codes.length;
		while(true)
		{
            size_t tlen = len - (ptr - _codes.ptr);
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
            size_t index = ptr - _codes.ptr;
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
	alias LAMBDA = bool delegate(String value);
    bool forEachValueOfHeader(STR)(STR key,scope LAMBDA func)
	{
        string name = cast(string)key;
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
            tlen = ptr - _codes.ptr;
			ptr ++;
			if(func(_headerValues[tlen]))
				return true;
		}
		return false;
	}
private :
    CodeArray _codes ;// = Vector!(HTTPHeaderCode)(2);
	StringArray _headersNames ;
	StringArray _headerValues ;
	size_t _deletedCount = 0;
}

template isYuString(STR)
{
    enum isYuString = (is(STR == String));
}
