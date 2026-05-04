# frozen_string_literal: true

require "json"
require "socket"
require "thread"

class FakeMcpHttpServer
  attr_reader :received

  def self.open(response_handler)
    server = new(response_handler)
    yield server.endpoint, server.received
    server.raise_error!
  ensure
    server&.shutdown
  end

  def initialize(response_handler)
    @response_handler = response_handler
    @received = []
    @errors = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def endpoint
    "http://127.0.0.1:#{@server.addr[1]}/mcp"
  end

  def shutdown
    @server.close unless @server.closed?
    @thread.join
  end

  def raise_error!
    raise @errors.pop unless @errors.empty?
  end

  private

  def serve
    loop do
      handle(@server.accept)
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(client)
    request_line = client.gets
    return write_json(client, 400, "error" => "missing request line") if request_line.to_s.empty?

    headers = read_headers(client)
    body = read_body(client, headers)
    payload = JSON.parse(body)
    @received << { "authorization" => headers["authorization"], "body" => payload }

    write_json(client, 200, @response_handler.call(payload))
  rescue StandardError => e
    @errors << e
    write_json(client, 500, "error" => e.message)
  ensure
    client.close unless client.closed?
  end

  def read_headers(client)
    headers = {}
    while (line = client.gets)
      stripped = line.strip
      break if stripped.empty?

      name, value = stripped.split(":", 2)
      headers[name.downcase] = value.to_s.strip if name
    end
    headers
  end

  def read_body(client, headers)
    length = headers.fetch("content-length", "0").to_i
    length.positive? ? client.read(length).to_s : ""
  end

  def write_json(client, status, payload)
    body = JSON.generate(payload)
    reason = status == 200 ? "OK" : "Error"
    client.write(
      "HTTP/1.1 #{status} #{reason}\r\n" \
      "Content-Type: application/json\r\n" \
      "Content-Length: #{body.bytesize}\r\n" \
      "Connection: close\r\n" \
      "\r\n" \
      "#{body}"
    )
  end
end
