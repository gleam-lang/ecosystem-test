import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/function
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/package_interface
import gleam/result
import gtabler
import simplifile
import tom

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
  let releases =
    packages
    |> list.filter_map(get_releases(_, token))
    |> list.flatten

  io.println("")

  let rows =
    releases
    |> list.sort(fn(a, b) { int.compare(b.downloads, a.downloads) })
    |> list.take(100)
    |> list.index_map(fn(release, i) {
      [
        int.to_string(i + 1),
        release.package,
        release.version,
        int.to_string(release.downloads),
      ]
    })

  gtabler.TableConfig(
    separator: " | ",
    border_char: "-",
    header_color: function.identity,
    cell_color: function.identity,
  )
  |> gtabler.print_table(["", "Package", "Version", "Downloads"], rows)
  |> io.println

  Nil
}

fn get_releases(
  package: ApiPackage,
  token: String,
) -> Result(List(Release), Nil) {
  let ApiPackage(name:, repository:, updated_at: _) = package

  use github <- result.try(case repository {
    option.Some("https://github.com/" <> github) -> Ok(github)
    option.Some(_) | option.None -> Error(Nil)
  })

  let assert Ok(_) =
    simplifile.create_directory_all("packages/" <> package.name)

  let assert Ok(request) =
    request.to("https://packages.gleam.run/api/packages/" <> name)

  let assert Ok(response) = httpc.send(request)

  case response.status {
    200 -> Nil
    x -> panic as { name <> " api failed " <> int.to_string(x) }
  }

  let assert Ok(releases) =
    json.parse(
      response.body,
      decode.at(["data", "releases"], decode.list(release_decoder())),
    )

  // Find releases we don't have a file locally for yet
  let #(releases, missing_releases) =
    releases
    |> list.filter(fn(release) { release.updated_at >= oldest })
    |> list.map(fn(release) {
      read_from_cache(package.name, release.version)
      |> result.replace_error(release)
    })
    |> result.partition

  // If there's no missing releases there's nothing more to do
  case missing_releases {
    [] -> Ok(releases)
    _ -> {
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

      let releases =
        missing_releases
        |> list.filter_map(fn(r) {
          let result = list.find(tags, fn(t) { t.name == "v" <> r.version })
          use tag <- result.try(result)
          let result = determine_support(package.name, r.version)
          use #(erlang, javascript) <- result.try(result)
          Ok(Release(
            package: package.name,
            version: r.version,
            sha: tag.sha,
            downloads: r.downloads,
            erlang:,
            javascript:,
          ))
        })
        |> list.map(fn(release) {
          let path = cache_path(release.package, release.version)
          let assert Ok(_) = simplifile.write(path, release_to_toml(release))
          io.println(".")
          release
        })
        |> list.append(releases)

      Ok(releases)
    }
  }
}

fn cache_path(package: String, version: String) -> String {
  "packages/" <> package <> "/" <> version <> ".toml"
}

fn read_from_cache(package: String, version: String) -> Result(Release, Nil) {
  case simplifile.read(cache_path(package, version)) {
    Ok(toml) -> toml_to_release(package, version, toml)
    Error(_) -> Error(Nil)
  }
}

fn toml_to_release(
  package: String,
  version: String,
  toml: String,
) -> Result(Release, Nil) {
  use toml <- result.try(tom.parse(toml) |> result.replace_error(Nil))
  {
    use sha <- result.try(tom.get_string(toml, ["sha"]))
    use erlang <- result.try(tom.get_bool(toml, ["erlang"]))
    use javascript <- result.try(tom.get_bool(toml, ["javascript"]))
    use downloads <- result.try(tom.get_int(toml, ["downloads"]))
    Ok(Release(package:, version:, sha:, downloads:, erlang:, javascript:))
  }
  |> result.replace_error(Nil)
}

fn release_to_toml(release: Release) -> String {
  let bool = fn(b) {
    case b {
      True -> "true"
      False -> "false"
    }
  }
  "sha = \"" <> release.sha <> "\"
erlang = " <> bool(release.erlang) <> "
javascript = " <> bool(release.javascript) <> "
downloads = " <> int.to_string(release.downloads) <> "
"
}

fn determine_support(
  name: String,
  version: String,
) -> Result(#(Bool, Bool), Nil) {
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
    package: String,
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
