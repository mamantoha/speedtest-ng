require "xml"
require "crest"

module Speedtest::Cli
  VERSION = "0.1.0"

  def self.fetch_servers
    url = "https://www.speedtest.net/speedtest-servers.php"
    response = Crest.get(url)

    if response.success?
      parse_servers(response.body)
    else
      raise "Failed to fetch Speedtest servers: #{response.status_code}"
    end
  end

  # Parses XML and gets the first server
  def self.parse_servers(xml_data : String)
    xml = XML.parse(xml_data)
    first_server = xml.xpath_nodes("//servers/server").first?

    if first_server
      {
        id: first_server["id"]?.to_s,
        name: first_server["name"]?.to_s,
        country: first_server["country"]?.to_s,
        url: first_server["url"]?.to_s
      }
    else
      raise "No servers found."
    end
  end

  # Performs a parallel download test
  def self.test_download_speed(server_url : String)
    # Ensure the URL is cleaned (remove upload.php if present)
    base_url = server_url.sub(/\/upload\.php$/, "")

    test_sizes = [350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000]
    download_count = 1

    puts "Testing download speed from: #{base_url}"
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
              bytes_received = response.body.bytesize
              total_bytes.add(bytes_received)
            end
          rescue ex
            puts "Error downloading #{url}: #{ex.message}"
          ensure
            channel.send(nil) # Signal that this fiber is done
          end
        end
      end
    end

    # Wait for all fibers to complete
    (test_sizes.size * download_count).times { channel.receive }

    end_time = Time.monotonic
    time_taken = (end_time - start_time).total_seconds

    # Convert bytes to megabits per second (Mbps)
    speed_mbps = (total_bytes.get * 8) / (time_taken * 1_000_000.0)

    puts "Download Speed: #{speed_mbps.round(2)} Mbps"
  end

  def self.test_upload_speed(server_url : String)
    # Ensure the URL is cleaned (remove upload.php if present)
    base_url = server_url.sub(/\/upload\.php$/, "")

    upload_sizes = [32768, 65536, 131072, 262144, 524288, 1048576, 7340032]
    upload_count = 1
    upload_url = "#{base_url}/upload.php"

    puts "Testing upload speed to: #{upload_url}"
    total_bytes = Atomic(Int64).new(0)
    start_time = Time.monotonic
    channel = Channel(Nil).new(upload_sizes.size * upload_count)

    upload_sizes.each do |size|
      upload_count.times do
        spawn do
          begin
            random_data = Random::Secure.random_bytes(size)  # Generate random payload
            response = HTTP::Client.post(upload_url, body: random_data)

            if response.success?
              total_bytes.add(size)
            end
          rescue ex
            puts "Error uploading #{size} bytes: #{ex.message}"
          ensure
            channel.send(nil)
          end
        end
      end
    end

    # Wait for all fibers to complete
    (upload_sizes.size * upload_count).times { channel.receive }

    end_time = Time.monotonic
    time_taken = (end_time - start_time).total_seconds

    speed_mbps = (total_bytes.get * 8) / (time_taken * 1_000_000.0)

    puts "Upload Speed: #{speed_mbps.round(2)} Mbps"
  end

  def self.run
    server = fetch_servers
    puts "Using Server: #{server[:name]}, #{server[:country]}"
    test_download_speed(server[:url])
    test_upload_speed(server[:url])
  end
end

Speedtest::Cli.run
