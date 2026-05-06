# frozen_string_literal: true

module Aiweb
  class LocalBackendDaemon
    MAX_BODY_BYTES = 1_048_576
    MAX_CONNECTIONS = 32
    READ_TIMEOUT_SECONDS = 5
    MAX_REQUEST_LINE_BYTES = 8_192
    MAX_HEADER_LINE_BYTES = 8_192
    MAX_HEADER_BYTES = 32_768

    attr_reader :host, :port, :app

    def initialize(host: "127.0.0.1", port: 4242, app: LocalBackendApp.new)
      @host = LocalBackendApp.normalize_host!(host)
      @port = LocalBackendApp.normalize_port!(port)
      @app = app
    end

    def self.plan(host: "127.0.0.1", port: 4242, bridge: CodexCliBridge.new)
      LocalBackendApp.plan(host: host, port: port, bridge: bridge)
    end

    def start
      server = TCPServer.new(host, port)
      slots = SizedQueue.new(MAX_CONNECTIONS)
      MAX_CONNECTIONS.times { slots << true }
      warn "aiweb local backend listening on http://#{host}:#{server.addr[1]}"
      warn "aiweb local backend token header: X-Aiweb-Token: #{app.api_token}" if ENV[LocalBackendApp::API_TOKEN_ENV].to_s.empty?
      loop do
        slot = slots.pop
        client = server.accept
        Thread.new(client, slot) do |socket, acquired_slot|
          begin
            handle(socket)
          ensure
            slots << acquired_slot
          end
        end
      end
    rescue Interrupt
      0
    ensure
      server&.close unless server&.closed?
    end

    private

    def handle(client)
      request_line = read_limited_line(client, MAX_REQUEST_LINE_BYTES, "request line")
      method, target = request_line.split(" ", 3)
      headers = read_headers(client)
      unless LocalBackendApp.allowed_origin?(headers["origin"])
        write_json(client, 403, "schema_version" => 1, "status" => "error", "error" => "origin is not allowed", "blocking_issues" => ["origin is not allowed"], origin: nil)
        return
      end
      body = read_body(client, headers)
      status, payload = app.call(method.to_s, target.to_s, headers, body)
      write_json(client, status, payload, origin: headers["origin"])
    rescue UserError => e
      status = e.exit_code == 5 ? 403 : 400
      write_json(client, status, "schema_version" => 1, "status" => "error", "error" => e.message, "blocking_issues" => [e.message])
    rescue StandardError => e
      write_json(client, 500, "schema_version" => 1, "status" => "error", "error" => "#{e.class}: #{e.message}")
    ensure
      client.close unless client.closed?
    end

    def read_headers(client)
      headers = {}
      bytes = 0
      while (line = read_limited_line(client, MAX_HEADER_LINE_BYTES, "header line"))
        bytes += line.bytesize
        raise UserError.new("request headers too large", 1) if bytes > MAX_HEADER_BYTES

        stripped = line.strip
        break if stripped.empty?

        name, value = stripped.split(":", 2)
        headers[name.downcase] = value.to_s.strip if name
      end
      headers
    end

    def read_body(client, headers)
      return read_chunked_body(client) if headers["transfer-encoding"].to_s.downcase.include?("chunked")

      length = headers.fetch("content-length", "0").to_i
      unless headers.fetch("content-length", "0").to_s.match?(/\A\d+\z/)
        raise UserError.new("invalid content length", 1)
      end
      raise UserError.new("invalid content length", 1) if length.negative?
      raise UserError.new("request body too large", 1) if length > MAX_BODY_BYTES

      length.positive? ? read_exact(client, length) : ""
    end

    def read_chunked_body(client)
      body = +""
      loop do
        size_line = read_limited_line(client, 32, "chunk size").strip
        raise UserError.new("invalid chunk size", 1) unless size_line.match?(/\A[0-9a-fA-F]+\z/)

        size = size_line.to_i(16)
        break if size.zero?
        raise UserError.new("request body too large", 1) if body.bytesize + size > MAX_BODY_BYTES

        body << read_exact(client, size)
        read_exact(client, 2)
      end
      read_headers(client)
      body
    end

    def read_limited_line(client, limit, label)
      line = Timeout.timeout(READ_TIMEOUT_SECONDS) { client.gets(limit + 1) }
      return nil if line.nil?
      raise UserError.new("#{label} too large", 1) if line.bytesize > limit

      line
    rescue Timeout::Error
      raise UserError.new("#{label} read timed out", 1)
    end

    def read_exact(client, length)
      Timeout.timeout(READ_TIMEOUT_SECONDS) { client.read(length).to_s }
    rescue Timeout::Error
      raise UserError.new("request body read timed out", 1)
    end

    def write_json(client, status, payload, origin: nil)
      body = JSON.generate(payload)
      reason = status == 200 ? "OK" : (status == 204 ? "No Content" : "Error")
      cors_origin = LocalBackendApp.allowed_origin?(origin) && !origin.to_s.strip.empty? ? origin.to_s.strip : nil
      cors_headers = +""
      if cors_origin
        cors_headers << "Access-Control-Allow-Origin: #{cors_origin}\r\n"
        cors_headers << "Vary: Origin\r\n"
      end
      client.write(
        "HTTP/1.1 #{status} #{reason}\r\n" \
        "Content-Type: application/json\r\n" \
        "#{cors_headers}" \
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" \
        "Access-Control-Allow-Headers: Content-Type, X-Aiweb-Token, X-Aiweb-Approval-Token\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n" \
        "#{body}"
      )
    end
  end
end
