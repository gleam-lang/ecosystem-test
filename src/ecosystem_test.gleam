import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/package_interface
import gleam/result
import simplifile

// Mar 04, 2024
const oldest = 1_709_568_875

pub fn main() -> Nil {
  let assert Ok(token) = envoy.get("GITHUB_TOKEN")
  let assert Ok(request) = request.to("https://packages.gleam.run/api/packages")
  let assert Ok(response) = httpc.send(request)
  let assert Ok(packages) =
    json.parse(
      response.body,
      decode.at(["data"], decode.list(package_decoder())),
    )
  packages
  |> list.each(update_package(_, token))
}

fn update_package(package: ApiPackage, token: String) -> Result(Nil, Nil) {
  let ApiPackage(name:, repository:, updated_at: _) = package
  io.print("\n" <> name)

  use github <- result.try(case repository {
    option.Some("https://github.com/" <> github) -> Ok(github)
    option.Some(_) | option.None -> Error(Nil)
  })

  let assert Ok(request) =
    request.to("https://packages.gleam.run/api/packages/" <> name)

  let assert Ok(response) = httpc.send(request)

  use _ <- result.try(case response.status {
    200 -> Ok(Nil)
    _ -> Error(Nil)
  })

  let assert Ok(releases) =
    json.parse(
      response.body,
      decode.at(["data", "releases"], decode.list(release_decoder())),
    )

  // Find releases we don't have a file locally for yet
  let missing_releases =
    releases
    |> list.filter(fn(release) { release.updated_at >= oldest })
    |> list.reverse
    |> list.filter(fn(release) {
      let path = "packages/" <> name <> "/" <> release.version <> ".toml"
      simplifile.is_file(path) == Ok(False)
    })

  // If there's no missing releases there's nothing more to do
  use _ <- result.try(case missing_releases {
    [] -> Error(Nil)
    _ -> Ok(Nil)
  })

  io.print(" .")

  // TODO: follow redirects
  let assert Ok(request) =
    request.to("https://api.github.com/repos/" <> github <> "/tags")
  let request =
    request
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_header("x-github-api-version", "2022-11-28")

  let assert Ok(response) = httpc.send(request)

  use _ <- result.try(case response.status {
    200 -> Ok(Nil)
    403 -> panic as "rate limited"
    _ -> Error(Nil)
  })

  let assert Ok(tags) =
    json.parse(response.body, decode.list(api_tag_decoder()))

  let assert Ok(_) =
    simplifile.create_directory_all("packages/" <> package.name)

  let releases =
    missing_releases
    |> list.filter_map(fn(r) {
      let result = list.find(tags, fn(t) { t.name == "v" <> r.version })
      use tag <- result.try(result)
      let result = determine_support(package.name, r.version)
      use #(erlang, javascript) <- result.try(result)
      Ok(Release(
        version: r.version,
        sha: tag.sha,
        downloads: r.downloads,
        erlang:,
        javascript:,
      ))
    })

  let bool = fn(b) {
    case b {
      True -> "true"
      False -> "false"
    }
  }

  releases
  |> list.each(fn(release) {
    let path = "packages/" <> package.name <> "/" <> release.version <> ".toml"
    let toml = "sha = \"" <> release.sha <> "\"
erlang = " <> bool(release.erlang) <> "
javascript = " <> bool(release.javascript) <> "
downloads = " <> int.to_string(release.downloads) <> "
"

    let assert Ok(_) = simplifile.write(path, toml)
    io.print(" " <> release.version)
  })

  Ok(Nil)
}

fn determine_support(
  name: String,
  version: String,
) -> Result(#(Bool, Bool), Nil) {
  io.print(".")
  let url =
    "https://hexdocs.pm/" <> name <> "/" <> version <> "/package-interface.json"
  let assert Ok(request) = request.to(url)
  let assert Ok(response) = httpc.send(request)

  use _ <- result.try(case response.status {
    200 -> Ok(Nil)
    // This package is lacking a package interface
    404 -> Error(Nil)
    _ -> panic as { name <> "@" <> version <> " interface " <> response.body }
  })

  let assert Ok(interface) =
    json.parse(response.body, package_interface.decoder())

  let functions =
    interface.modules
    |> dict.values
    |> list.flat_map(fn(m) { dict.values(m.functions) })

  let erlang =
    list.all(functions, fn(f) { f.implementations.can_run_on_erlang })
  let javascript =
    list.all(functions, fn(f) { f.implementations.can_run_on_javascript })
  Ok(#(erlang, javascript))
}

type Release {
  Release(
    version: String,
    sha: String,
    downloads: Int,
    erlang: Bool,
    javascript: Bool,
  )
}

type ApiRelease {
  ApiRelease(version: String, updated_at: Int, downloads: Int)
}

fn release_decoder() -> decode.Decoder(ApiRelease) {
  use version <- decode.field("version", decode.string)
  use updated_at <- decode.field("updated-at", decode.int)
  use downloads <- decode.field("downloads", decode.int)
  decode.success(ApiRelease(version:, updated_at:, downloads:))
}

type ApiPackage {
  ApiPackage(name: String, repository: Option(String), updated_at: Int)
}

fn package_decoder() -> decode.Decoder(ApiPackage) {
  use name <- decode.field("name", decode.string)
  use repository <- decode.field("repository", decode.optional(decode.string))
  use updated_at <- decode.field("updated-at", decode.int)
  decode.success(ApiPackage(name:, repository:, updated_at:))
}

type ApiTag {
  ApiTag(name: String, sha: String)
}

fn api_tag_decoder() -> decode.Decoder(ApiTag) {
  use name <- decode.field("name", decode.string)
  use sha <- decode.subfield(["commit", "sha"], decode.string)
  decode.success(ApiTag(name:, sha:))
}
