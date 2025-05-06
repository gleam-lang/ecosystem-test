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
import gleam/string
import gtabler
import simplifile
import tom

const config = Config(
  // Mar 04, 2024
  oldest: 1_709_568_875,
  fetch_missing: False,
  test_erlang: False,
  test_javascript: True,
  count: 256,
  print_table: False,
  create_workflow: True,
)

pub type Config {
  Config(
    oldest: Int,
    count: Int,
    test_erlang: Bool,
    test_javascript: Bool,
    fetch_missing: Bool,
    print_table: Bool,
    create_workflow: Bool,
  )
}

fn override(release: Release) -> Release {
  case release {
    // Outdated deps
    Release(package: "gleam_http", version: "1." <> _, ..)
    | Release(package: "gleam_http", version: "2." <> _, ..)
    | Release(package: "gleam_http", version: "3." <> _, ..)
    | Release(package: "arctic_plugin_diagram", version: "0." <> _, ..)
    | Release(package: "arctic_plugin_diagram", version: "1." <> _, ..)
    | Release(package: "cors_builder", version: "2." <> _, ..) ->
      Release(..release, javascript: False, erlang: False)

    // Erlang specific tests
    Release(package: "gleam_crypto", ..)
    | Release(package: "wisp_flash", ..)
    | Release(package: "nakai", version: "0." <> _, ..)
    | Release(package: "nakai", version: "1." <> _, ..)
    | Release(package: "storail", version: "3." <> _, ..)
    | Release(package: "cachmere", version: "0." <> _, ..)
    | Release(package: "shine_tree", version: "0." <> _, ..)
    | Release(package: "worm", version: "1." <> _, ..)
    | Release(package: "bucket", version: "1." <> _, ..)
    | Release(package: "based_sqlite", version: "3." <> _, ..)
    | Release(package: "glance_printer", version: "1." <> _, ..)
    | Release(package: "glance_printer", version: "2." <> _, ..)
    | Release(package: "json_typedef", version: "1." <> _, ..)
    | Release(package: "spinner", ..) -> Release(..release, javascript: False)

    // Uses services in tests
    Release(package: "cake", ..) ->
      Release(..release, javascript: False, erlang: False)

    // Uses python stuff in tests
    Release(package: "go_over", ..) ->
      Release(..release, javascript: False, erlang: False)

    // Uses node modules in tests
    Release(package: "lenient_parse", ..) ->
      Release(..release, javascript: False, erlang: False)

    // Broken with older Gleam versions
    Release(package: "gtempo", version: "5." <> _, ..)
    | Release(package: "gtempo", version: "6." <> _, ..) ->
      Release(..release, javascript: False, erlang: False)

    // Broken
    Release(package: "glenv", version: "0." <> _, ..)
    | Release(package: "based_sqlite", version: "2." <> _, ..)
    | Release(package: "sqlight", version: "0." <> _, ..)
    | Release(package: "cactus", version: "1.3.3", ..)
    | Release(package: "party", version: "1" <> _, ..)
    | Release(package: "clip", version: "0.6.1", ..)
    | Release(package: "qcheck", version: "0" <> _, ..)
    | Release(package: "humanise", version: "1.0.2", ..)
    | Release(package: "glearray", version: "0" <> _, ..)
    | Release(package: "glearray", version: "1" <> _, ..)
    | Release(package: "glearray", version: "2" <> _, ..)
    | Release(package: "handles", version: "4" <> _, ..)
    | Release(package: "jot", version: "1." <> _, ..)
    | Release(package: "jot", version: "2." <> _, ..)
    | Release(package: "jot", version: "3." <> _, ..) ->
      Release(..release, javascript: False, erlang: False)

    // Unsupported monorepo
    Release(package: "redraw", ..)
    | Release(package: "redraw_dom", ..)
    | Release(package: "palabres", ..)
    | Release(package: "palabres_wisp", ..) ->
      Release(..release, javascript: False, erlang: False)

    // No tests
    Release(package: "lucide_lustre", ..)
    | Release(package: "gleroglero", ..)
    | Release(package: "vleam", ..)
    | Release(package: "repeatedly", ..) ->
      Release(..release, javascript: False, erlang: False)

    _ -> release
  }
}

pub fn main() -> Nil {
  let assert Ok(token) = envoy.get("GITHUB_TOKEN")
  let assert Ok(request) = request.to("https://packages.gleam.run/api/packages")
  io.print(".")
  let assert Ok(response) = httpc.send(request)
  let assert Ok(packages) =
    json.parse(
      response.body,
      decode.at(["data"], decode.list(package_decoder())),
    )
  let releases =
    packages
    |> list.flat_map(get_releases(_, token))
    |> list.sort(fn(a, b) { int.compare(b.downloads, a.downloads) })
    |> list.filter(fn(release) {
      case config.test_erlang, config.test_javascript {
        True, True -> release.erlang || release.javascript
        True, _ -> release.erlang
        _, True -> release.javascript
        _, _ -> False
      }
    })
    |> list.take(config.count)

  case config.print_table {
    True -> print_table(releases)
    False -> Nil
  }

  case config.create_workflow {
    True -> create_workflow(releases)
    False -> Nil
  }

  Nil
}

fn create_workflow(releases: List(Release)) -> Nil {
  let workflow =
    "
name: ecosystem-test

on:
  workflow_dispatch:
    inputs:
      gleam-version:
        description: 'Gleam version'
        required: true
        default: '1.10.0'

jobs:
"
  let workflow =
    list.fold(releases, workflow, fn(workflow, release) {
      case release.github, release.sha {
        option.Some(github), option.Some(sha) -> {
          let name =
            string.replace(release.package <> "-" <> release.version, ".", "_")

          let workflow = workflow <> "
  " <> name <> ":
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          repository: '" <> github <> "'
          ref: '" <> sha <> "'
      - uses: erlef/setup-beam@v1
        with:
          otp-version: '27'
          gleam-version: '1.10.0'
          rebar3-version: '3'
          elixir-version: '1'
      - uses: actions/setup-node@v4
        with:
          node-version: '18.x'
      - name: Setup Deno
        uses: denoland/setup-deno@v2
      - name: Setup Bun
        uses: oven-sh/setup-bun@v2
"
          let workflow = case config.test_erlang && release.erlang {
            False -> workflow
            True -> workflow <> "      - run: gleam test --target erlang\n"
          }
          case config.test_javascript && release.javascript {
            False -> workflow
            True -> workflow <> "      - run: gleam test --target js\n"
          }
        }
        _, _ -> workflow
      }
    })

  let assert Ok(_) =
    simplifile.write(".github/workflows/ecosystem-test.yml", workflow)

  Nil
}

fn print_table(releases: List(Release)) -> Nil {
  let rows =
    releases
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
}

fn get_github_and_tags(
  package: ApiPackage,
  token: String,
) -> #(Option(String), List(ApiTag)) {
  case package.repository {
    option.Some("https://github.com/" <> github) -> {
      // TODO: follow redirects
      let assert Ok(request) =
        request.to("https://api.github.com/repos/" <> github <> "/tags")
      let request =
        request
        |> request.set_header("authorization", "Bearer " <> token)
        |> request.set_header("x-github-api-version", "2022-11-28")

      io.print(".")
      let assert Ok(response) = httpc.send(request)

      case response.status {
        200 -> {
          let assert Ok(tags) =
            json.parse(response.body, decode.list(api_tag_decoder()))
          #(option.Some(github), tags)
        }
        403 -> panic as "rate limited"
        _ -> #(option.None, [])
      }
    }
    option.Some(_) | option.None -> #(option.None, [])
  }
}

fn get_releases(package: ApiPackage, token: String) -> List(Release) {
  let assert Ok(_) =
    simplifile.create_directory_all("packages/" <> package.name)
  case config.fetch_missing {
    True -> lookup_releases(package, token)
    False -> get_releases_from_cache(package)
  }
}

fn get_releases_from_cache(package: ApiPackage) -> List(Release) {
  let path = "packages/" <> package.name
  let assert Ok(files) = simplifile.read_directory(path)
  let assert Ok(releases) =
    list.try_map(files, fn(file) {
      read_from_cache(package.name, string.drop_end(file, 5))
    })
  releases
}

fn lookup_releases(package: ApiPackage, token: String) -> List(Release) {
  let ApiPackage(name:, repository: _, updated_at: _) = package
  let assert Ok(request) =
    request.to("https://packages.gleam.run/api/packages/" <> name)

  io.print(".")
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
    |> list.filter(fn(release) { release.updated_at >= config.oldest })
    |> list.map(fn(release) {
      read_from_cache(package.name, release.version)
      |> result.replace_error(release)
    })
    |> result.partition

  case missing_releases {
    // If there's no missing releases there's nothing more to do
    [] -> releases
    _ -> {
      let #(github, tags) = get_github_and_tags(package, token)

      let releases =
        missing_releases
        |> list.filter_map(fn(r) {
          let sha = case list.find(tags, fn(t) { t.name == "v" <> r.version }) {
            Ok(tag) -> option.Some(tag.sha)
            Error(_) -> option.None
          }
          let #(erlang, javascript) = determine_support(package.name, r.version)
          let release =
            Release(
              package: package.name,
              version: r.version,
              github:,
              sha:,
              downloads: r.downloads,
              erlang:,
              javascript:,
            )
          Ok(override(release))
        })
        |> list.map(fn(release) {
          let path = cache_path(release.package, release.version)
          let assert Ok(_) = simplifile.write(path, release_to_toml(release))
          io.print(".")
          release
        })
        |> list.append(releases)

      releases
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
    let sha = case tom.get_string(toml, ["sha"]) {
      Ok(sha) -> option.Some(sha)
      Error(_) -> option.None
    }
    let github = case tom.get_string(toml, ["github"]) {
      Ok(github) -> option.Some(github)
      Error(_) -> option.None
    }
    use erlang <- result.try(tom.get_bool(toml, ["erlang"]))
    use javascript <- result.try(tom.get_bool(toml, ["javascript"]))
    use downloads <- result.try(tom.get_int(toml, ["downloads"]))
    let release =
      Release(
        package:,
        version:,
        github:,
        sha:,
        downloads:,
        erlang:,
        javascript:,
      )
    Ok(override(release))
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
  let toml = case release.sha {
    option.Some(sha) -> "sha = \"" <> sha <> "\"\n"
    option.None -> ""
  }
  let toml = case release.github {
    option.Some(github) -> toml <> "github = \"" <> github <> "\"\n"
    option.None -> toml
  }

  toml <> "erlang = " <> bool(release.erlang) <> "
javascript = " <> bool(release.javascript) <> "
downloads = " <> int.to_string(release.downloads) <> "
"
}

fn determine_support(name: String, version: String) -> #(Bool, Bool) {
  let url =
    "https://hexdocs.pm/" <> name <> "/" <> version <> "/package-interface.json"
  let assert Ok(request) = request.to(url)
  io.print(".")
  let assert Ok(response) = httpc.send(request)

  case response.status {
    200 -> {
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
      #(erlang, javascript)
    }
    // This package is lacking a package interface
    404 -> #(False, False)
    _ -> panic as { name <> "@" <> version <> " interface " <> response.body }
  }
}

type Release {
  Release(
    package: String,
    version: String,
    github: Option(String),
    sha: Option(String),
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
