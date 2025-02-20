# speedtest-cli

A command-line tool for testing internet speed using Speedtest.net, written in Crystal.
Inspired by the Python-based [speedtest-cli](https://www.speedtest.net/).

## Installation

Clone the repository:

```sh
git clone https://github.com/mamantoha/speedtest-cli
cd speedtest-cli
```

Build the project:

```sh
shards build --release
```

Or build manually:

```sh
crystal build src/speedtest-cli.cr --release
```

## Usage

```
./speedtest-cli
```

## Contributing

1. Fork it (<https://github.com/mamantoha/speedtest-cli/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Anton Maminov](https://github.com/mamantoha) - creator and maintainer
