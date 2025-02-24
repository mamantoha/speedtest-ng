require "http/client"
require "xml"
require "option_parser"
require "haversine"

module Speedtest
  extend self

  alias Server = NamedTuple(
    url: String,
    lat: Float64,
    lon: Float64,
    name: String,
    country: String,
    cc: String,
    sponsor: String,
    id: String,
    host: String,
  )

  class Config
    getter client : NamedTuple(ip: String, isp: String, country: String, lat: Float64, lon: Float64)
    getter upload_threads : Int32
    getter download_threads : Int32

    def initialize(xml_content : String)
      xml = XML.parse(xml_content)

      @client = {
        ip:      xml.xpath_string("string(//client/@ip)"),
        isp:     xml.xpath_string("string(//client/@isp)"),
        country: xml.xpath_string("string(//client/@country)"),
        lat:     xml.xpath_float("number(//client/@lat)"),
        lon:     xml.xpath_float("number(//client/@lon)"),
      }

      @upload_threads = xml.xpath_string("string(//upload/@threads)").to_i || 2
      @download_threads = xml.xpath_string("string(//download/@threadsperurl)").to_i || 4
    end
  end

  def fetch_speedtest_config : Config
    url = "https://www.speedtest.net/speedtest-config.php"

    puts "🚀 Fetching Speedtest Configuration..."

    response = HTTP::Client.get(url)

    if response.success?
      Config.new(response.body)
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
        lat:     server["lat"].to_f,
        lon:     server["lon"].to_f,
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

    puts hosted_server_info(best_server, best_latency)

    best_server
  end

  def test_download_speed(host : String, config : Config, single_mode : Bool)
    base_url = "http://#{host}/speedtest"
    download_sizes = [350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000].reverse
    threads = single_mode ? 1 : config.download_threads
    total_requests = download_sizes.size * threads

    total_bytes = Atomic(Int64).new(0)
    completed_requests = Atomic(Int32).new(0)
    start_time = Time.monotonic

    puts "⬇️ Testing download speed..."

    download_sizes.each do |size|
      url = "#{base_url}/random#{size}x#{size}.jpg"

      channel = Channel(Nil).new(threads)

      threads.times do
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

      threads.times { channel.receive }
    end

    puts "\n"
    end_time = Time.monotonic
    total_time = end_time - start_time

    puts "🔼 Download: #{speed_in_mbps(total_bytes.get, total_time)}"
  end

  def test_upload_speed(host : String, config : Config, single_mode : Bool)
    url = "http://#{host}/speedtest/upload.php"

    upload_sizes = [32768, 65536, 131072, 262144, 524288, 1048576, 7340032].reverse
    threads = single_mode ? 1 : config.upload_threads
    total_requests = upload_sizes.size * threads

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

      channel = Channel(Nil).new(threads)

      threads.times do
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

      threads.times { channel.receive }
    end

    puts "\n"
    end_time = Time.monotonic
    total_time = end_time - start_time

    puts "🔼 Upload: #{speed_in_mbps(total_bytes.get, total_time)}"
  end

  def list_servers
    config = fetch_speedtest_config
    servers = fetch_servers

    client_lat = config.client[:lat]
    client_lon = config.client[:lon]

    server_distances = servers.map do |server|
      distance = Haversine.distance(client_lat, client_lon, server[:lat], server[:lon])
      {server: server, distance: distance}
    end

    server_distances.sort_by!(&.[:distance])

    server_distances.each do |entry|
      server = entry[:server]
      distance_km = entry[:distance].to_kilometers.round(2)
      flag = country_flag(server[:cc])

      printf(
        "  %-8s %s [%s km]\n",
        server[:id],
        "#{server[:sponsor]} (#{server[:name]}, #{flag} #{server[:country]})",
        distance_km
      )
    end
  end

  def hosted_server_info(server : Server, latency : Float64? = nil) : String
    flag = country_flag(server[:cc])

    if latency
      "📍 Hosted by #{server[:sponsor]} (#{server[:name]}, #{flag} #{server[:country]}): #{latency.round(2)} ms"
    else
      "📍 Hosted by #{server[:sponsor]} (#{server[:name]}, #{flag} #{server[:country]})"
    end
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

  private def update_progress_bar(start_time : Time::Span, total_bytes : Int64, completed_requests : Int32, total_requests : Int32)
    sleep 100.milliseconds
    elapsed_time = Time.monotonic - start_time

    speed_mbps = speed_in_mbps(total_bytes, elapsed_time)

    percentage = ((completed_requests / total_requests) * 100).clamp(0, 100).to_i
    bar_length = (percentage / 2).to_i
    progress_bar = "=" * bar_length + ">"

    printf("\r%3d%% [%-51s] %15s", percentage, progress_bar.ljust(50), speed_mbps)
    STDOUT.flush
  end

  private def speed_in_mbps(bytes : Int64, elapsed_time : Time::Span) : String
    avg_speed = (bytes * 8) / (elapsed_time.total_seconds * 1_000_000.0)

    "#{avg_speed.round(2)} Mbit/s"
  end

  module CLI
    NAME    = "speedtest-ng"
    VERSION = "0.1.0"

    def self.run
      no_download = false
      no_upload = false
      single_mode = false
      list_servers_only = false
      server_id = nil

      OptionParser.parse do |parser|
        parser.banner = "Usage: #{NAME} [options]"

        parser.on("--no-download", "Do not perform download test") { no_download = true }
        parser.on("--no-upload", "Do not perform upload test") { no_upload = true }
        parser.on("--single", "Only use a single connection (simulates file transfer)") { single_mode = true }
        parser.on("--list", "Display a list of speedtest.net servers sorted by distance") { list_servers_only = true }
        parser.on("--server SERVER", "Specify a server ID to test against") { |id| server_id = id }
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

      if list_servers_only
        Speedtest.list_servers

        exit(0)
      end

      config = Speedtest.fetch_speedtest_config

      puts "🌍 Testing from #{Speedtest.country_flag(config.client[:country])} #{config.client[:isp]} (#{config.client[:ip]})..."

      servers = Speedtest.fetch_servers

      selected_server =
        if server_id
          server = servers.find { |s| s[:id] == server_id }

          if server.nil?
            puts "❌ Error: Server ID #{server_id} not found in the available list."
            exit(1)
          end

          puts Speedtest.hosted_server_info(server)

          server
        else
          Speedtest.fetch_best_server(servers)
        end

      Speedtest.test_download_speed(selected_server[:host], config, single_mode) unless no_download
      Speedtest.test_upload_speed(selected_server[:host], config, single_mode) unless no_upload
    end
  end
end
