require "http/client"
require "xml"
require "option_parser"

module Speedtest::Cli
  VERSION = "0.1.0"

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

  class SpeedtestConfig
    getter client_ip : String
    getter client_isp : String
    getter upload_maxchunkcount : Int32
    getter upload_threads : Int32
    getter download_threadsperurl : Int32

    def initialize(xml_content : String)
      xml = XML.parse(xml_content)

      @client_ip = xml.xpath_string("string(//client/@ip)")
      @client_isp = xml.xpath_string("string(//client/@isp)")
      @upload_maxchunkcount = xml.xpath_string("string(//upload/@maxchunkcount)").to_i || 10
      @upload_threads = xml.xpath_string("string(//upload/@threads)").to_i || 2
      @download_threadsperurl = xml.xpath_string("string(//download/@threadsperurl)").to_i || 4
    end
  end

  def self.fetch_speedtest_config : SpeedtestConfig
    url = "https://www.speedtest.net/speedtest-config.php"

    response = HTTP::Client.get(url)

    if response.success?
      return SpeedtestConfig.new(response.body)
    else
      puts "Error fetching Speedtest configuration: #{response.status_code}"
      exit(1)
    end
  rescue ex
    puts "Error fetching config: #{ex.message}"
    exit(1)
  end

  def self.fetch_servers : Array(Server)
    puts "Retrieving speedtest.net server list..."

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

  def self.fetch_best_server(servers) : Server
    puts "Selecting best server based on ping..."

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

    puts "Hosted by #{best_server[:sponsor]} (#{best_server[:name]}, #{best_server[:country]}): #{best_latency.round(2)} ms"

    best_server
  end

  def self.test_download_speed(host : String, config : SpeedtestConfig)
    base_url = "http://#{host}/speedtest"

    test_sizes = [350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000]
    download_count = config.download_threadsperurl

    print "Testing download speed: "

    total_bytes = Atomic(Int64).new(0)
    start_time = Time.monotonic
    channel = Channel(Nil).new(test_sizes.size * download_count)

    test_sizes.each do |size|
      download_count.times do
        spawn do
          url = "#{base_url}/random#{size}x#{size}.jpg"
          begin
            response = HTTP::Client.get(url)
            if response.success?
              total_bytes.add(response.body.bytesize)
              print "."
              STDOUT.flush
            end
          rescue
            print "E"
          ensure
            channel.send(nil)
          end
        end
      end
    end

    (test_sizes.size * download_count).times { channel.receive }

    puts "\n"
    end_time = Time.monotonic
    time_taken = (end_time - start_time).total_seconds
    speed_mbps = (total_bytes.get * 8) / (time_taken * 1_000_000.0)

    puts "Download: #{speed_mbps.round(2)} Mbit/s"
  end

  def self.test_upload_speed(host : String, config : SpeedtestConfig)
    upload_url = "http://#{host}/speedtest/upload.php"

    upload_sizes = [32768, 65536, 131072, 262144, 524288, 1048576, 7340032]
    upload_max = config.upload_maxchunkcount
    upload_count = (upload_max / upload_sizes.size).ceil.to_i

    print "Testing upload speed: "

    total_bytes = Atomic(Int64).new(0)
    start_time = Time.monotonic
    channel = Channel(Nil).new(upload_sizes.size * upload_count)

    upload_sizes.each do |size|
      upload_count.times do
        spawn do
          begin
            random_data = Random::Secure.random_bytes(size)
            response = HTTP::Client.post(upload_url, body: random_data)
            if response.success?
              total_bytes.add(size)
              print "."
              STDOUT.flush
            end
          rescue
            print "E"
          ensure
            channel.send(nil)
          end
        end
      end
    end

    (upload_sizes.size * upload_count).times { channel.receive }

    puts "\n"
    end_time = Time.monotonic
    time_taken = (end_time - start_time).total_seconds
    speed_mbps = (total_bytes.get * 8) / (time_taken * 1_000_000.0)

    puts "Upload: #{speed_mbps.round(2)} Mbit/s"
  end

  def self.run
    no_download = false
    no_upload = false

    OptionParser.parse do |parser|
      parser.banner = "Usage: speedtest-cli [options]"

      parser.on("--no-download", "Do not perform download test") { no_download = true }
      parser.on("--no-upload", "Do not perform upload test") { no_upload = true }
      parser.on("--version", "Show the version number and exit") do
        puts "Speedtest CLI #{VERSION}"
        puts "Crystal #{Crystal::VERSION} (LLVM #{Crystal::LLVM_VERSION})"
        exit
      end
      parser.on("-h", "--help", "Show this help message and exit") do
        puts parser
        exit
      end
    end

    puts "Retrieving speedtest.net configuration..."
    config = fetch_speedtest_config

    puts "Testing from #{config.client_isp} (#{config.client_ip})..."

    servers = fetch_servers
    best_server = fetch_best_server(servers)

    test_download_speed(best_server[:host], config) unless no_download
    test_upload_speed(best_server[:host], config) unless no_upload
  end
end

Speedtest::Cli.run
