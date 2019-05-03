# Copyright, 2017, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative 'buffer'
require_relative 'generic'

module Async
	module IO
		class Stream
			BLOCK_SIZE = IO::BLOCK_SIZE
			
			def initialize(io, block_size: BLOCK_SIZE, sync: true)
				@io = io
				@eof = false
				
				# We don't want Ruby to do any IO buffering.
				@io.sync = sync
				
				@block_size = block_size
				
				@read_buffer = Buffer.new
				@write_buffer = Buffer.new
				
				# Used as destination buffer for underlying reads.
				@input_buffer = Buffer.new
			end
			
			attr :io
			attr :block_size
			
			# Reads exactly `size` bytes from the stream. If size is not specified, read until end of file.
			# @raise EOFError if the requested number of bytes could not be read.
			def read(size = nil)
				return '' if size == 0
				
				if size
					until @read_buffer.size >= size
						# Compute the amount of data we need to read from the underlying stream:
						read_size = size - @read_buffer.bytesize
						
						# Don't read less than @block_size to avoid lots of small reads:
						fill_read_buffer(read_size > @block_size ? read_size : @block_size)
						
						eof! if @eof
					end
				else
					until @eof
						fill_read_buffer
					end
				end
				
				return consume_read_buffer(size)
			end
			
			# Read at most `size` bytes from the stream. Will avoid reading from the underlying stream if possible.
			def read_partial(size = nil)
				return '' if size == 0 
				
				unless @eof
					if size and @read_buffer.bytesize <= size
						fill_read_buffer(size > @block_size ? size : @block_size)
					elsif @read_buffer.empty?
						fill_read_buffer
					end
				end
				
				return consume_read_buffer(size)
			end
			
			alias readpartial read_partial
			
			# Efficiently read data from the stream until encountering pattern.
			# @param pattern [String] The pattern to match.
			# @return [String] The contents of the stream up until the pattern, which is consumed but not returned.
			def read_until(pattern, offset = 0, chomp: true)
				# We don't want to split on the pattern, so we subtract the size of the pattern.
				split_offset = pattern.bytesize - 1
				
				until index = @read_buffer.index(pattern, offset)
					offset = @read_buffer.size - split_offset
					
					offset = 0 if offset < 0
					
					return unless fill_read_buffer
				end
				
				@read_buffer.freeze
				matched = @read_buffer.byteslice(0, index+(chomp ? 0 : pattern.bytesize))
				@read_buffer = @read_buffer.byteslice(index+pattern.bytesize, @read_buffer.bytesize)
				
				return matched
			end
			
			def peek
				until yield(@read_buffer) or @eof
					fill_read_buffer
				end
			end
			
			# Writes `string` to the buffer. When the buffer is full or #sync is true the
			# buffer is flushed to the underlying `io`.
			# @param string the string to write to the buffer.
			# @return the number of bytes appended to the buffer.
			def write(string)
				if @write_buffer.empty? and string.bytesize >= @block_size
					@io.write(string)
				else
					@write_buffer << string
					
					if @write_buffer.size >= @block_size
						@io.write(@write_buffer)
						@write_buffer.clear
					end
				end
				
				return string.bytesize
			end
			
			# Writes `string` to the stream and returns self.
			def <<(string)
				write(string)
				
				return self
			end
			
			# Flushes buffered data to the stream.
			def flush
				unless @write_buffer.empty?
					@io.write(@write_buffer)
					@write_buffer.clear
				end
			end
			
			def gets(separator = $/, **options)
				read_until(separator, **options)
			end
			
			def puts(*args, separator: $/)
				args.each do |arg|
					@write_buffer << arg << separator
				end
				
				flush
			end
			
			def connected?
				@io.connected?
			end
			
			def closed?
				@io.closed?
			end
			
			def close_read
				@io.close_read
			end
			
			def close_write
				flush
			ensure
				@io.close_write
			end
			
			# Best effort to flush any unwritten data, and then close the underling IO.
			def close
				return if @io.closed?
				
				begin
					flush
				rescue
					# We really can't do anything here unless we want #close to raise exceptions.
					Async.logger.error(self) {$!}
				ensure
					@io.close
				end
			end
			
			# Returns true if the stream is at file which means there is no more data to be read.
			def eof?
				fill_read_buffer if !@eof && @read_buffer.empty?
				
				return @eof && @read_buffer.empty?
			end
			
			alias eof eof?
			
			def eof!
				@read_buffer.clear
				@eof = true
				
				raise EOFError
			end
			
			private
			
			# Fills the buffer from the underlying stream.
			def fill_read_buffer(size = @block_size)
				if @read_buffer.empty? and @io.read_nonblock(size, @read_buffer, exception: false)
					return true
				elsif chunk = @io.read_nonblock(size, @input_buffer, exception: false)
					@read_buffer << chunk
					return true
				else
					# We didn't read anything, so we must be at eof:
					@eof = true
					return false
				end
			end
			
			# Consumes at most `size` bytes from the buffer.
			# @param size [Integer|nil] The amount of data to consume. If nil, consume entire buffer.
			def consume_read_buffer(size = nil)
				# If we are at eof, and the read buffer is empty, we can't consume anything.
				return nil if @eof && @read_buffer.empty?
				
				result = nil
				
				if size.nil? or size >= @read_buffer.size
					# Consume the entire read buffer:
					result = @read_buffer
					@read_buffer = Buffer.new
				else
					# This approach uses more memory.
					# result = @read_buffer.slice!(0, size)
					
					# We know that we are not going to reuse the original buffer.
					# But byteslice will generate a hidden copy. So let's freeze it first:
					@read_buffer.freeze
					
					result = @read_buffer.byteslice(0, size)
					@read_buffer = @read_buffer.byteslice(size, @read_buffer.bytesize)
				end
				
				return result
			end
		end
	end
end
