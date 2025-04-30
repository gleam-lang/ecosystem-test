import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

// Mar 04, 2024
const oldest = 1_709_568_875

pub fn main() -> Nil {
  let assert Ok(request) = request.to("https://packages.gleam.run/api/packages")
  let assert Ok(response) = httpc.send(request)
  let assert Ok(packages) =
    json.parse(
      response.body,
      decode.at(["data"], decode.list(package_decoder())),
    )
  let packages =
    packages
    |> list.take_while(fn(package) { package.updated_at >= oldest })
    |> list.filter_map(lookup_package)
  list.each(packages, fn(p) { io.println(string.inspect(p)) })
  Nil
}

fn lookup_package(package: ApiPackage) -> Result(Package, Nil) {
  let ApiPackage(name:, version:, repository:, updated_at: _) = package

  use package <- result.try(case repository {
    option.Some("https://github.com/" <> github) ->
      Ok(Package(name:, version:, github:))
    option.Some(_) | option.None -> Error(Nil)
  })

  Ok(package)
}

pub type Package {
  Package(name: String, version: String, github: String)
}

pub type ApiPackage {
  ApiPackage(
    name: String,
    version: String,
    repository: Option(String),
    updated_at: Int,
  )
}

fn package_decoder() -> decode.Decoder(ApiPackage) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("latest-version", decode.string)
  use repository <- decode.field("repository", decode.optional(decode.string))
  use updated_at <- decode.field("updated-at", decode.int)
  decode.success(ApiPackage(name:, version:, repository:, updated_at:))
}
