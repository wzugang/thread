
local alien = require "alien"
local bit = require "bit"
local thread = require "thread"
local type = type

module(..., package.seeall)

local file_meta = alien.tag("aio_file")

local libc = alien.default

libc.strerror:types("string", "int")
libc.open:types("int", "string", "int", "int")
libc.close:types("int", "int")
libc.read:types("int", "int", "string", "int")
libc.write:types("int", "int","string", "int")
libc.fdopen:types("pointer", "int", "string")
libc.fgets:types("int", "string", "int", "pointer")
libc.ferror:types("int", "pointer")
libc.strlen:types("int", "string")
libc.fscanf:types("int", "pointer", "string", "ref double")
libc.fcntl:types("int", "int", "int", "int")
libc.popen:types("pointer", "string", "string")
libc.fileno:types("int", "pointer")
libc.fflush:types("int", "pointer")
libc.fseek:types("int", "pointer", "int", "int")
libc.setvbuf:types("int", "pointer", "string", "int", "int")

require("aio_constants")

local STDIN, STDOUT, STDERR = 0, 1, 2

local mode2flags = {
  ["r"] = O_RDONLY,
  ["rb"] = O_RDONLY,
  ["r+"] = bit.bor(O_RDWR, O_CREAT),
  ["rb+"] = bit.bor(O_RDWR, O_CREAT),
  ["r+b"] = bit.bor(O_RDWR, O_CREAT),
  ["w"] = bit.bor(O_WRONLY, O_CREAT, O_TRUNC),
  ["wb"] = bit.bor(O_WRONLY, O_CREAT, O_TRUNC),
  ["a"] = bit.bor(O_WRONLY, O_CREAT, O_APPEND),
  ["ab"] = bit.bor(O_WRONLY, O_CREAT, O_APPEND),
  ["w+"] = bit.bor(O_RDWR, O_CREAT, O_TRUNC),
  ["wb"] = bit.bor(O_RDWR, O_CREAT, O_TRUNC),
  ["w+b"] = bit.bor(O_RDWR, O_CREAT, O_TRUNC),
  ["a+"] = bit.bor(O_RDWR, O_CREAT, O_APPEND),
  ["ab+"] = bit.bor(O_RDWR, O_CREAT, O_APPEND),
  ["a+b"] = bit.bor(O_RDWR, O_CREAT, O_APPEND)
}

local function tofile(file)
  local ok, fd, stream = pcall(alien.unwrap, "aio_file", file)
  if not ok then
    error("not an async IO stream!")
  elseif not stream then
    error(debug.traceback("attempt to use a closed file"))
  else
    return fd, stream
  end
end

local function aio_error(path)
  local en = alien.errno()
  local err = libc.strerror(en)
  if path then
    return nil, string.format("%s: %s", path, err)
  else
    return nil, err
  end
end

local open_streams = {}

function open(path, mode)
  mode = mode or "r"
  local flags = mode2flags[mode]
  flags = bit.bor(flags, O_NONBLOCK)
  local fd = libc.open(path, flags, DEFFILEMODE)
  if fd ~= -1 then
    local stream = libc.fdopen(fd, mode)
    if stream then
      open_streams[fd] = stream
      local file = alien.wrap("aio_file", fd, stream)
      return file
    else
      return aio_error(path)
    end
  else
    return aio_error(path)
  end
end

function close(file)
  local fd, stream = alien.unwrap("aio_file", file)
  if stream then
    local status = libc.close(fd)
    if status ~= -1 then
      open_streams[fd] = nil
      alien.rewrap("aio_file", file, -1, nil)
      return true
    else
      return aio_error()
    end
  end
  return true
end

function _M.type(file)
  local ok, fd, stream = pcall(alien.unwrap, "aio_file", file)
  if not ok then
    return nil
  elseif stream then
    return "file"
  else
    return "closed file"
  end
end

local buffer_queue = {}
setmetatable(buffer_queue, { __mode = "v" })

local function get_buffer()
  if #buffer_queue == 0 then
    return alien.buffer(BUFSIZ)
  else
    return table.remove(buffer_queue)
  end
end

local function dispose_buffer(buf)
  table.insert(buffer_queue, buf)
end

local ___i = 0

local function aio_read_bytes(fd, n)
  local buf = get_buffer()
  local out = {}
  local r = n
  while n > 0 and r > 0 do
    local size = math.min(n, BUFSIZ)
    r = libc.read(fd, buf, size)
    if r == -1 then
      local en = alien.errno()
      if en == EAGAIN then
	r = 1
	thread.yield("read", fd)
      else
	dispose_buffer(buf)
	return nil, libc.strerror(en)
      end
    else
      if r > 0 then out[#out + 1] = buf:tostring(r) end
      n = n - r
    end
  end
  dispose_buffer(buf)
  if #out > 0 then return table.concat(out) else return nil end
end

local function aio_read_all(fd)
  return aio_read_bytes(fd, MAXINT)
end

local function aio_read_number(fd, stream)
  local n, out = libc.fscanf(stream, "%lf")
  if n == -1 then
    if libc.ferror(stream) ~= 0 then
      local en = alien.errno()
      if en == EAGAIN then
	thread.yield("read", fd)
	return aio_read_number(stream)
      else
	return nil, libc.strerror(en)
      end
    else
      return nil
    end
  elseif n == 0 then
    return nil
  else
    return out
  end
end

local function aio_read_line(fd, stream, buf)
  buf = buf or get_buffer()
  while true do
    local n = libc.fgets(buf, BUFSIZ, stream)
    if n == 0 then
      if libc.ferror(stream) ~= 0 then
	local en = alien.errno()
	if en == EAGAIN then
	  thread.yield("read", fd)
	else
	  dispose_buffer(buf)
	  return nil, libc.strerror(en)
	end
      else
	dispose_buffer(buf)
	return nil
      end
    else
      local res = buf:tostring()
      if not res:sub(#res) == "\n" then
	local next, err = aio_read_line(stream, buf)
	if err then return nil, err end
	dispose_buffer(buf)
	return res .. (next or "")
      else
	dispose_buffer(buf)
	return res:sub(1, #res - 1)
      end
    end
  end
end

local function aio_read_item(fd, stream, what)
  if type(what) == "number" then
    return aio_read_bytes(fd, what)
  elseif what == "*n" then
    return aio_read_number(fd, stream)
  elseif what == "*l" then
    return aio_read_line(fd, stream)
  elseif what == "*a" then
    return aio_read_all(fd)
  else
    error("invalid option")
  end
end

local function aio_read(file, ...)
  local fd, stream = tofile(file)
  local nargs = select("#", ...)
  if nargs == 0 then
    return aio_read_line(fd, stream)
  elseif nargs == 1 then
    return aio_read_item(fd, stream, ...)
  else
    local items = {}
    for i = 1, nargs do
      local what = select(i, ...)
      items[#items + 1] = aio_read_item(fd, stream, what)
    end
    return unpack(items)
  end
end

function read(...)
  return aio_read(stdin, ...)
end

local function aio_write_item(fd, item)
  local s = tostring(item)
  local size = string.len(s)
  local w = libc.write(fd, s, size)
  if w == -1 then
    local en = alien.errno()
    if en == EAGAIN then
      thread.yield("write", fd)
      return aio_write_item(fd, s)
    else
      return false
    end
  else
    return w == size
  end
end

local function aio_write(file, ...)
  local fd = tofile(file)
  local nargs = select("#", ...)
  local status = true
  for i = 1, nargs do
    status = status and aio_write_item(fd, select(i, ...))
  end
  if not status then
    return nil, libc.strerror(alien.errno())
  else
    return true
  end
end

function write(...)
  return aio_write(stdout, ...)
end

function lines(file)
  file = file or stdin
  if type(file) == "string" then
    file = open(file, "r")
  end
  return function ()
	   return file:read("*l")
	 end
end

function popen(cmd, mode)
  mode = mode or "r"
  local stream = libc.popen(cmd, mode)
  if stream then
    local fd = libc.fileno(stream)
    local status = libc.fcntl(fd, F_GETFL, 0)
    status = libc.fcntl(fd, F_SETFL, bit.bor(status, O_NONBLOCK))
    if status ~= -1 then
      return alien.wrap("aio_file", fd, stream)
    end
  end
  return aio_error(cmd)
end

local function aio_flush(file)
  local fd, stream = tofile(file)
  if libc.fflush(stream) ~= 0 then
    local en = alien.errno()
    if en == EAGAIN then
      thread.yield("write", fd)
      return aio_flush(file)
    else
      return nil, lib.strerror(en)
    end
  else
    return true
  end
end

function flush()
  return aio_flush(stdout)
end

local seek_whence = {
  cur = SEEK_CUR,
  set = SEEK_SET,
  ["end"] = SEEK_END
}

local function aio_seek(file, whence, offset)
  if type(whence) == "number" then
    whence, offset = nil, whence
  end
  local n_whence, offset = seek_whence[whence or "cur"], offset or 0
  if not n_whence then error("invalid option for file:seek") end
  local fd, stream = tofile(file)
  if libc.fseek(stream, offset, n_whence) ~= 0 then
    local en = alien.errno()
    if en == EAGAIN then
      thread.yield("write", fd)
      return aio_seek(file, whence, offset)
    else
      return nil, lib.strerror(en)
    end
  else
    return true
  end
end

local setvbuf_mode = {
  no = _IONBF,
  full = _IOFBF,
  line = _IOLBF
}

local function aio_setvbuf(file, mode, size)
  local n_mode, size = setvbuf_mode[mode], size or 0
  if not n_mode then error("invalid option for file:setvbuf") end
  local fd, stream = tofile(file)
  if libc.setvbuf(stream, nil, n_mode, size) ~= 0 then
    return aio_error()
  else
    return true
  end
end

function input(file)
  local f
  if type(file) == "string" then
    f = open(file, "r")
  elseif f then
    tofile(file)
    f = file
  else
    f = stdin
  end
  stdin = f
end

function output(file)
  local f
  if type(file) == "string" then
    f = open(file, "w")
  elseif f then
    tofile(file)
    f = file
  else
    f = stdout
  end
  stdout = f
end

file_meta.__gc = close

file_meta.__index = {
  read = aio_read,
  write = aio_write,
  close = close,
  lines = lines,
  flush = aio_flush,
  seek = aio_seek,
  setvbuf = aio_setvbuf
}

do
  local status = libc.fcntl(STDIN, F_GETFL, 0)
  if libc.fcntl(STDIN, F_SETFL, bit.bor(status, O_NONBLOCK)) == -1 then
    error("could not set stdin to not block")
  end
  local status = libc.fcntl(STDOUT, F_GETFL, 0)
  if libc.fcntl(STDOUT, F_SETFL, bit.bor(status, O_NONBLOCK)) == -1 then
    error("could not set stdout to not block")
  end
  local status = libc.fcntl(STDERR, F_GETFL, 0)
  if libc.fcntl(STDERR, F_SETFL, bit.bor(status, O_NONBLOCK)) == -1 then
    error("could not set stderr to not block")
  end
end

stdin = alien.wrap("aio_file", STDIN, libc.fdopen(STDIN, "r"))
stdout = alien.wrap("aio_file", STDOUT, libc.fdopen(STDOUT, "w"))
stderr = alien.wrap("aio_file", STDERR, libc.fdopen(STDERR, "w"))
