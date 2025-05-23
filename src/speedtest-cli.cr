require "http/client"
require "xml"
require "json"
require "option_parser"
require "wait_group"
require "upload_io"
require "haversine"
require "tablo"

module Speedtest
  extend self

  private PROGRESS_MUTEX = Mutex.new

  alias Servers = Array(Server)

  class Server
    include JSON::Serializable

    property url : String
    property lat : String
    property lon : String
    property distance : Int32
    property name : String
    property country : String
    property cc : String
    property sponsor : String
    property id : String
    property preferred : Int32
    property https_functional : Int32
    property host : String
    property force_ping_select : Int32?
  end

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

  def fetch_servers : Servers
    puts "📡 Retrieving speedtest.net server list..."

    url = "https://www.speedtest.net/api/js/servers?engine=js&limit=10&https_functional=true"

    response = HTTP::Client.get(url)

    Servers.from_json(response.body)
  end

  def fetch_best_server(servers : Array(Server), secure : Bool) : {Server, Float64}
    puts "🎯 Selecting the best server based on ping..."

    best_server = nil
    best_latency = Float64::INFINITY

    servers.each do |server|
      avg_latency = get_server_latency(server, secure)

      next unless avg_latency

      if avg_latency < best_latency
        best_latency = avg_latency
        best_server = server
      end
    end

    if best_server.nil?
      puts "❌ No available servers!"
      exit(1)
    end

    {best_server, best_latency}
  end

  def test_download_speed(
    host : String,
    config : Config,
    single_mode : Bool,
    secure : Bool,
    time_limit : Time::Span = 20.seconds,
  )
    Speedtest.test_in_progress = true

    scheme = secure ? "https" : "http"

    download_sizes = [
      25_000_000,
      15_000_000,
      10_000_000,
      5_000_000,
      2_000_000,
      1_000_000,
      500_000,
      250_000,
    ]

    threads = single_mode ? 1 : config.download_threads
    total_bytes = (download_sizes.sum * threads).to_i64
    transferred_bytes = Atomic(Int64).new(0)

    buffer_size = 4096
    buffer = Bytes.new(buffer_size)

    download_queue = Channel(String).new

    spawn do
      (download_sizes * threads).shuffle.each do |size|
        download_queue.send("#{scheme}://#{host}/download?size=#{size}")
      end

      download_queue.close
    end

    start_time = Time.monotonic
    done = Channel(Nil).new

    spawn do
      loop do
        select
        when done.receive?
          break
        when timeout(1.second)
          update_progress_bar(start_time, transferred_bytes.get, total_bytes)
        end
      end
    end

    puts "⬇️ Testing download speed..."

    WaitGroup.wait do |wg|
      threads.times do
        wg.spawn do
          while url = download_queue.receive?
            break if (Time.monotonic - start_time) > time_limit || !Speedtest.test_in_progress

            begin
              HTTP::Client.get(url) do |response|
                loop do
                  break if (Time.monotonic - start_time) > time_limit || !Speedtest.test_in_progress

                  bytes_read = response.body_io.read(buffer)

                  break if bytes_read.zero?

                  transferred_bytes.add(bytes_read)
                end
              end
            rescue
            end
          end
        end
      end
    end

    done.send(nil)
    update_progress_bar(start_time, transferred_bytes.get, transferred_bytes.get)

    puts "\n"
    total_time = Time.monotonic - start_time

    puts "🔽 Download: #{speed_in_mbps(transferred_bytes.get, total_time)} (#{transferred_bytes.get.humanize_bytes} in #{total_time.seconds} seconds)"
  end

  def test_upload_speed(
    host : String,
    config : Config,
    single_mode : Bool,
    secure : Bool,
    time_limit : Time::Span = 20.seconds,
  )
    Speedtest.test_in_progress = true

    scheme = secure ? "https" : "http"

    url = "#{scheme}://#{host}/upload"

    upload_sizes = [
      32768,
      65536,
      131072,
      262144,
      524288,
      1048576,
      7340032,
    ]

    threads = single_mode ? 1 : config.upload_threads
    total_bytes = (upload_sizes.sum * threads).to_i64
    transferred_bytes = Atomic(Int64).new(0)

    buffer_size = 4096

    upload_data = upload_sizes.each_with_object({} of Int32 => Bytes) do |size, hash|
      hash[size] = Random::Secure.random_bytes(size)
    end

    upload_queue = Channel(Int32).new

    spawn do
      (upload_sizes * threads).shuffle.each { |size| upload_queue.send(size) }

      upload_queue.close
    end

    start_time = Time.monotonic
    done = Channel(Nil).new

    spawn do
      loop do
        select
        when done.receive?
          break
        when timeout(1.second)
          update_progress_bar(start_time, transferred_bytes.get, total_bytes)
        end
      end
    end

    puts "⬆️ Testing upload speed..."

    WaitGroup.wait do |wg|
      threads.times do
        wg.spawn do
          while size = upload_queue.receive?
            break if (Time.monotonic - start_time) > time_limit || !Speedtest.test_in_progress

            begin
              upload_io = UploadIO.new(upload_data[size], buffer_size) do |io|
                io.on_progress ->(bytes_read : Int32) { transferred_bytes.add(bytes_read) }
                io.should_cancel -> { (Time.monotonic - start_time) > time_limit || !Speedtest.test_in_progress }
              end

              headers = HTTP::Headers{
                "Content-Type"   => "application/octet-stream",
                "Content-Length" => size.to_s,
              }

              HTTP::Client.post(url, headers: headers, body: upload_io)
            rescue
            end
          end
        end
      end
    end

    done.send(nil)
    update_progress_bar(start_time, transferred_bytes.get, transferred_bytes.get)

    puts "\n"
    total_time = Time.monotonic - start_time

    puts "🔼 Upload: #{speed_in_mbps(transferred_bytes.get, total_time)} (#{transferred_bytes.get.humanize_bytes} in #{total_time.seconds} seconds)"
  end

  def list_servers
    config = fetch_speedtest_config
    servers = fetch_servers

    client_lat = config.client[:lat]
    client_lon = config.client[:lon]

    server_distances = servers.map do |server|
      distance = Haversine.distance(client_lat, client_lon, server.lat.to_f, server.lon.to_f)
      {server: server, distance: distance}
    end

    server_distances.sort_by!(&.[:distance])

    data = server_distances.map do |entry|
      server = entry[:server]
      distance_km = entry[:distance].to_kilometers.round(2)
      flag = country_flag(server.cc)

      [
        server.id.to_s,
        "#{server.sponsor} (#{server.name}, #{flag} #{server.country})",
        "#{distance_km} km",
      ]
    end

    name_width = data.max_of(&.[1].size)

    table = Tablo::Table.new(data) do |t|
      t.add_column("ID", &.[0])
      t.add_column("Server", width: name_width, &.[1])
      t.add_column("Distance", &.[2])
    end

    puts table
  end

  def hosted_server_info(server : Server, config : Config, *, latency : Float64? = nil, secure : Bool = false) : String
    flag = country_flag(server.cc)

    client_lat = config.client[:lat]
    client_lon = config.client[:lon]

    distance = Haversine.distance(client_lat, client_lon, server.lat.to_f, server.lon.to_f)

    result = "📍 Hosted by #{server.sponsor} (#{server.name}, #{flag} #{server.country}) [#{distance.to_kilometers.round(2)} km]"

    unless latency
      latency = get_server_latency(server, secure)
    end

    if latency
      result = result + ": #{latency.round(2)} ms"
    end

    result
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

  private def get_server_latency(server : Server, secure : Bool) : Float64?
    latencies = [] of Float64

    begin
      scheme = secure ? "https" : "http"
      http_client = HTTP::Client.new(URI.parse("#{scheme}://#{server.host}"))
      http_client.connect_timeout = 1.seconds

      3.times do
        start_time = Time.monotonic

        begin
          response = http_client.get("/speedtest/latency.txt")

          if response.success?
            elapsed_time = (Time.monotonic - start_time).total_milliseconds
            latencies << elapsed_time
          end
        rescue IO::TimeoutError
          return nil
        rescue
          next
        end
      end

      http_client.close
    rescue
      return nil
    end

    return nil if latencies.empty?

    latencies.sum / latencies.size
  end

  private def update_progress_bar(start_time : Time::Span, bytes : Int64, total_bytes : Int64)
    elapsed_time = Time.monotonic - start_time

    speed_mbps = speed_in_mbps(bytes, elapsed_time)

    percentage =
      if bytes.zero? || total_bytes.zero?
        0
      else
        ((bytes / total_bytes) * 100).clamp(0, 100).to_i
      end

    bar_length = (percentage / 2).to_i
    progress_bar = "=" * bar_length + ">"

    PROGRESS_MUTEX.synchronize do
      printf("\r%3d%% [%-51s] %15s", percentage, progress_bar.ljust(50), speed_mbps)
      STDOUT.flush
    end
  end

  private def speed_in_mbps(bytes : Int64, elapsed_time : Time::Span) : String
    avg_speed = (bytes * 8) / (elapsed_time.total_seconds * 1_000_000.0)

    "%.2f Mbit/s" % avg_speed
  end

  module CLI
    NAME       = "speedtest-ng"
    VERSION    = {{ `shards version #{__DIR__}`.chomp.stringify }}
    BUILD_DATE = {{ `crystal eval "puts Time.utc"`.stringify.chomp }}

    def self.run
      no_download = false
      no_upload = false
      single_mode = false
      list_servers_only = false
      server_id = nil
      secure = false
      download_time_limit = 20.seconds
      upload_time_limit = 20.seconds

      OptionParser.parse do |parser|
        parser.banner = "Usage: #{NAME} [options]"

        parser.on("--no-download", "Do not perform download test") do
          no_download = true
        end

        parser.on("--no-upload", "Do not perform upload test") do
          no_upload = true
        end

        parser.on("--single", "Only use a single connection (simulates file transfer)") do
          single_mode = true
        end

        parser.on("--list", "Display a list of speedtest.net servers sorted by distance") do
          list_servers_only = true
        end

        parser.on("--server SERVER", "Specify a server ID to test against") do |id|
          server_id = id
        end

        parser.on("--secure", "Use HTTPS instead of HTTP when communicating with speedtest.net operated servers") do
          secure = true
        end

        parser.on("--download-time SECONDS", "Set download test time limit in seconds (default: 20)") do |seconds|
          download_time_limit = seconds.to_i.seconds
        end

        parser.on("--upload-time SECONDS", "Set upload test time limit in seconds (default: 20)") do |seconds|
          upload_time_limit = seconds.to_i.seconds
        end

        parser.on("-v", "--version", "Show the version number and exit") do
          puts "#{NAME} #{VERSION} (#{BUILD_DATE})"
          puts
          puts "Crystal #{Crystal::VERSION} [LLVM #{Crystal::LLVM_VERSION}]"
          exit
        end
        parser.on("-h", "--help", "Show this help message and exit") do
          puts parser
          exit
        end

        parser.invalid_option do |flag|
          puts "error: unrecognized arguments: #{flag}"
          STDERR.puts parser
          exit(1)
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
        if id = server_id
          server = servers.find(&.id.==(id))

          if server.nil?
            puts "❌ Error: Server ID #{id} not found in the available list."
            exit(1)
          end

          puts Speedtest.hosted_server_info(server, config, secure: secure)

          server
        else
          server, latency = Speedtest.fetch_best_server(servers, secure)

          puts Speedtest.hosted_server_info(server, config, latency: latency, secure: secure)

          server
        end

      Speedtest.test_download_speed(
        selected_server.host,
        config,
        single_mode,
        secure,
        download_time_limit
      ) unless no_download

      Speedtest.test_upload_speed(
        selected_server.host,
        config,
        single_mode,
        secure,
        upload_time_limit
      ) unless no_upload
    end
  end
end
