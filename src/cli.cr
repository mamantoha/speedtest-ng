require "./speedtest-cli"

Process.on_terminate do
  puts
  puts "Cancelling..."
  exit
end

Speedtest::CLI.run
