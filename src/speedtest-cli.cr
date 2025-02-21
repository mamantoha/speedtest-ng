require "http/client"
require "xml"
require "option_parser"

module Speedtest
  extend self

  alias Server = NamedTuple(
    url: String,
    lat: String,
    lon: String,
    name: String,
    country: String,
    cc: String,
    sponsor: String,
    id: String,
    host: String,
  )

  class Config
    getter client_ip : String
    getter client_isp : String
    getter upload_threads : Int32
    getter download_threadsperurl : Int32

    def initialize(xml_content : String)
      xml = XML.parse(xml_content)

      @client_ip = xml.xpath_string("string(//client/@ip)")
      @client_isp = xml.xpath_string("string(//client/@isp)")
      @upload_threads = xml.xpath_string("string(//upload/@threads)").to_i || 2
      @download_threadsperurl = xml.xpath_string("string(//download/@threadsperurl)").to_i || 4
    end
  end

  def fetch_speedtest_config : Config
    url = "https://www.speedtest.net/speedtest-config.php"

    response = HTTP::Client.get(url)

    if response.success?
      return Config.new(response.body)
    else
      puts "Error fetching Speedtest configuration: #{response.status_code}"
      exit(1)
    end
  rescue ex
    puts "Error fetching config: #{ex.message}"
    exit(1)
  end

  def fetch_servers : Array(Server)
    puts "📡 Retrieving speedtest.net server list..."

    url = "https://www.speedtest.net/speedtest-servers.php"

    response = HTTP::Client.get(url)

    if response.status.redirection?
      response = HTTP::Client.get(response.headers["Location"])
    end

    unless response.success?
      puts "Failed to fetch Speedtest servers: #{response.status_code}"
      exit(1)
    end

    xml = XML.parse(response.body)

    xml.xpath_nodes("//servers/server").map do |server|
      {
        url:     server["url"],
        lat:     server["lat"],
        lon:     server["lon"],
        name:    server["name"],
        country: server["country"],
        cc:      server["cc"],
        sponsor: server["sponsor"],
        id:      server["id"],
        host:    server["host"],
      }
    end
  end

  def fetch_best_server(servers) : Server
    puts "🎯 Selecting the best server based on ping..."

    best_server = nil
    best_latency = Float64::INFINITY

    servers.each do |server|
      latency_url = "http://#{server[:host]}/speedtest/latency.txt"

      latencies = [] of Float64

      3.times do
        start_time = Time.monotonic
        begin
          response = HTTP::Client.get(latency_url)
          if response.success?
            elapsed_time = (Time.monotonic - start_time).total_milliseconds
            latencies << elapsed_time
          end
        rescue
          next
        end
      end

      next if latencies.empty?

      avg_latency = latencies.sort.first(3).sum / latencies.size

      if avg_latency < best_latency
        best_latency = avg_latency
        best_server = server
      end
    end

    if best_server.nil?
      puts "No available servers!"
      exit(1)
    end

    flag = country_flag(best_server[:cc])
    puts "📍 Hosted by #{best_server[:sponsor]} (#{best_server[:name]}, #{flag} #{best_server[:country]}): #{best_latency.round(2)} ms"

    best_server
  end

  def test_download_speed(host : String, config : Config)
    base_url = "http://#{host}/speedtest"
    download_sizes = [350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000].reverse
    download_count = config.download_threadsperurl
    total_requests = download_sizes.size * download_count

    total_bytes = Atomic(Int64).new(0)
    completed_requests = Atomic(Int32).new(0)
    start_time = Time.monotonic

    puts "⬇️ Testing download speed..."

    download_sizes.each do |size|
      url = "#{base_url}/random#{size}x#{size}.jpg"

      channel = Channel(Nil).new(download_count)

      download_count.times do
        spawn do
          begin
            response = HTTP::Client.get(url)

            if response.success?
              total_bytes.add(response.body.bytesize)
            end
          rescue
          ensure
            completed_requests.add(1)
            update_progress_bar(start_time, total_bytes.get, completed_requests.get, total_requests)
            channel.send(nil)
          end
        end
      end

      download_count.times { channel.receive }
    end

    puts "\n"
    end_time = Time.monotonic
    total_time = (end_time - start_time).total_seconds
    avg_speed = (total_bytes.get * 8) / (total_time * 1_000_000.0)

    puts "🔽 Download: #{avg_speed.round(2)} Mbit/s"
  end

  def test_upload_speed(host : String, config : Config)
    url = "http://#{host}/speedtest/upload.php"

    upload_sizes = [32768, 65536, 131072, 262144, 524288, 1048576, 7340032].reverse
    upload_count = config.upload_threads
    total_requests = upload_sizes.size * upload_count

    upload_data = upload_sizes.reduce({} of Int32 => Bytes) do |hash, size|
      hash[size] = Random::Secure.random_bytes(size)
      hash
    end

    total_bytes = Atomic(Int64).new(0)
    completed_requests = Atomic(Int32).new(0)
    start_time = Time.monotonic

    puts "⬆️ Testing upload speed..."

    upload_sizes.each do |size|
      data = upload_data[size]

      channel = Channel(Nil).new(upload_count)

      upload_count.times do
        spawn do
          begin
            response = HTTP::Client.post(url, body: data)

            if response.success?
              total_bytes.add(size)
            end
          rescue
          ensure
            completed_requests.add(1)
            update_progress_bar(start_time, total_bytes.get, completed_requests.get, total_requests)
            channel.send(nil)
          end
        end
      end

      upload_count.times { channel.receive }
    end

    puts "\n"
    end_time = Time.monotonic
    total_time = (end_time - start_time).total_seconds
    avg_speed = (total_bytes.get * 8) / (total_time * 1_000_000.0)

    puts "🔼 Upload: #{avg_speed.round(2)} Mbit/s"
  end

  def update_progress_bar(start_time : Time::Span, total_bytes : Int64, completed_requests : Int32, total_requests : Int32)
    elapsed_time = (Time.monotonic - start_time).total_seconds
    speed_mbps = elapsed_time > 0 ? (total_bytes * 8) / (elapsed_time * 1_000_000.0) : 0.0

    percentage = ((completed_requests / total_requests) * 100).clamp(0, 100).to_i
    bar_length = (percentage / 2).to_i
    progress_bar = "=" * bar_length + ">"

    printf("\r%3d%% [%-50s] %7.2f Mbit/s", percentage, progress_bar.ljust(50), speed_mbps)
    STDOUT.flush
  end

  def country_flag(code : String) : String
    offset = 127397
    country_code_re = /^[A-Z]{2}$/

    if country_code_re.match(code)
      code.codepoints.map(&.+ offset).join(&.chr)
    else
      ""
    end
  end

  module CLI
    NAME = "speedtest-ng"
    VERSION = "0.1.0"

    def self.run
      no_download = false
      no_upload = false

      OptionParser.parse do |parser|
        parser.banner = "Usage: #{NAME} [options]"

        parser.on("--no-download", "Do not perform download test") { no_download = true }
        parser.on("--no-upload", "Do not perform upload test") { no_upload = true }
        parser.on("--version", "Show the version number and exit") do
          puts "#{NAME} #{VERSION}"
          puts "Crystal #{Crystal::VERSION} [LLVM #{Crystal::LLVM_VERSION}]"
          exit
        end
        parser.on("-h", "--help", "Show this help message and exit") do
          puts parser
          exit
        end
      end

      puts "🚀 Fetching Speedtest Configuration..."
      config = Speedtest.fetch_speedtest_config

      puts "🌍 Testing from 🌐 #{config.client_isp} (#{config.client_ip})..."

      servers = Speedtest.fetch_servers
      best_server = Speedtest.fetch_best_server(servers)

      Speedtest.test_download_speed(best_server[:host], config) unless no_download
      Speedtest.test_upload_speed(best_server[:host], config) unless no_upload
    end
  end
end

Speedtest::CLI.run
