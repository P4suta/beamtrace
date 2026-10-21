use anyhow::{Context, Result, bail, ensure};
use beamtrace_release_tools::policy::{Action, Mode, decide};
use reqwest::blocking::{Client, RequestBuilder};
use reqwest::{Url, redirect, retry};
use serde::Deserialize;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::Duration;

const REPOSITORY: &str = "P4suta/beamtrace";
const REPOSITORY_ID: &str = "1343313550";
const OWNER_ID: &str = "42543015";
const AUDIENCE_URL: &str = "https://hex.pm/api/oidc/audience";
const TOKEN_URL: &str = "https://hex.pm/api/oauth/token";
const SCOPE: &str = "package:hexpm/beamtrace_core";
const RESPONSE_LIMIT: u64 = 65_536;
const TOKEN_LIMIT: usize = 16_384;
const MAX_TOKEN_SECONDS: u16 = 900;
const HTTPS_PORT: u16 = 443;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const ACKNOWLEDGEMENT: &[u8] = b"I am not using semantic versioning\n";

struct Github {
    request_url: Url,
    request_token: String,
}

#[derive(Deserialize)]
struct Audience {
    audience: String,
}

#[derive(Deserialize)]
struct GithubToken {
    value: String,
}

#[derive(Deserialize)]
struct Exchange {
    access_token: String,
    token_type: String,
    expires_in: u16,
    scope: String,
}

struct Token(String);

impl Token {
    fn into_header(self) -> String {
        format!("Bearer {}", self.0)
    }
}

fn environment(name: &str) -> Result<String> {
    std::env::var(name)
        .map_err(|_| anyhow::anyhow!("required GitHub environment input {name} is unavailable"))
}

fn request_url(value: &str) -> Result<Url> {
    let url = Url::parse(value)
        .map_err(|_| anyhow::anyhow!("invalid GitHub OIDC request URL; value withheld"))?;
    ensure!(
        url.scheme() == "https"
            && url
                .host_str()
                .is_some_and(|host| host.ends_with(".actions.githubusercontent.com"))
            && url.port_or_known_default() == Some(HTTPS_PORT)
            && url.username().is_empty()
            && url.password().is_none()
            && url.fragment().is_none(),
        "GitHub OIDC endpoint is outside its HTTPS origin"
    );
    Ok(url)
}

fn github() -> Result<Github> {
    ensure!(
        environment("GITHUB_ACTIONS")? == "true"
            && environment("GITHUB_REPOSITORY")? == REPOSITORY
            && environment("GITHUB_REPOSITORY_ID")? == REPOSITORY_ID
            && environment("GITHUB_REPOSITORY_OWNER_ID")? == OWNER_ID,
        "only the expected GitHub repository may exchange its workload identity"
    );
    for name in ["HEXPM_API_KEY", "HEX_API_KEY"] {
        ensure!(
            std::env::var_os(name).is_none_or(|value| value.is_empty()),
            "static Hex credentials are not accepted"
        );
    }
    Ok(Github {
        request_url: request_url(&environment("ACTIONS_ID_TOKEN_REQUEST_URL")?)?,
        request_token: environment("ACTIONS_ID_TOKEN_REQUEST_TOKEN")?,
    })
}

fn response<T: serde::de::DeserializeOwned>(request: RequestBuilder, operation: &str) -> Result<T> {
    let response = request
        .send()
        .map_err(|_| anyhow::anyhow!("{operation} request failed; private response withheld"))?;
    ensure!(
        response.status().is_success(),
        "{operation} returned HTTP {}; private response withheld",
        response.status().as_u16()
    );
    let mut bytes = Vec::new();
    response
        .take(RESPONSE_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| anyhow::anyhow!("{operation} response was incomplete; contents withheld"))?;
    ensure!(
        u64::try_from(bytes.len())? <= RESPONSE_LIMIT,
        "{operation} response exceeded its size limit"
    );
    serde_json::from_slice(&bytes)
        .map_err(|_| anyhow::anyhow!("{operation} returned invalid metadata; contents withheld"))
}

fn valid_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= TOKEN_LIMIT
        && value.bytes().all(|byte| byte.is_ascii_graphic())
}

fn scoped_token(exchange: Exchange) -> Result<Token> {
    ensure!(
        exchange.token_type.eq_ignore_ascii_case("bearer")
            && exchange.scope == SCOPE
            && exchange.expires_in > 0
            && exchange.expires_in <= MAX_TOKEN_SECONDS
            && valid_token(&exchange.access_token),
        "Hex returned an invalid package-scoped short-lived token; contents withheld"
    );
    Ok(Token(exchange.access_token))
}

fn authenticate(client: &Client, github: &Github) -> Result<Token> {
    let audience: Audience = response(client.get(AUDIENCE_URL), "Hex audience discovery")?;
    ensure!(
        !audience.audience.trim().is_empty() && audience.audience.len() <= TOKEN_LIMIT,
        "Hex audience is invalid"
    );
    let assertion: GithubToken = response(
        client
            .get(github.request_url.clone())
            .bearer_auth(&github.request_token)
            .query(&[("audience", audience.audience)]),
        "GitHub OIDC",
    )?;
    ensure!(
        valid_token(&assertion.value),
        "GitHub returned an invalid OIDC token; contents withheld"
    );
    let exchange = response(
        client.post(TOKEN_URL).form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            ("assertion", assertion.value.as_str()),
            ("scope", SCOPE),
        ]),
        "Hex token exchange",
    )?;
    scoped_token(exchange)
}

fn publish(token: Token) -> Result<()> {
    let mut child = Command::new("gleam")
        .args(["publish", "--yes"])
        .env("HEXPM_API_KEY", token.into_header())
        .env_remove("ACTIONS_ID_TOKEN_REQUEST_URL")
        .env_remove("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
        .stdin(Stdio::piped())
        .spawn()
        .context("starting Gleam failed")?;
    let mut input = child.stdin.take().context("Gleam input unavailable")?;
    let sent = input.write_all(ACKNOWLEDGEMENT);
    drop(input);
    let status = child.wait().context("waiting for Gleam failed")?;
    ensure!(sent.is_ok() && status.success(), "Gleam publication failed");
    Ok(())
}

fn complete(mode: Mode, token: Option<Token>) -> Result<()> {
    match decide(mode, token.is_some()) {
        Action::Refuse => bail!("Hex authentication is missing"),
        Action::Confirm => {
            println!("Hex package workload identity authenticated; no package published");
        }
        Action::Publish => publish(token.context("Hex authentication is missing")?)?,
    }
    Ok(())
}

fn run() -> Result<()> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let mode = match arguments.as_slice() {
        [mode] if mode == "--check" => Mode::Check,
        [mode] if mode == "--publish" => Mode::Publish,
        _ => bail!("usage: hex-workload --check|--publish"),
    };
    let github = github()?;
    let client = Client::builder()
        .https_only(true)
        .redirect(redirect::Policy::none())
        .retry(retry::never())
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|_| anyhow::anyhow!("creating HTTPS client failed"))?;
    complete(mode, Some(authenticate(&client, &github)?))
}

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exchange() -> Exchange {
        Exchange {
            access_token: "fixture-token".to_owned(),
            token_type: "bearer".to_owned(),
            expires_in: MAX_TOKEN_SECONDS,
            scope: SCOPE.to_owned(),
        }
    }

    #[test]
    fn token_scope_lifetime_and_header_format_are_mandatory() {
        assert!(scoped_token(exchange()).is_ok());
        for expires_in in [0, MAX_TOKEN_SECONDS + 1] {
            assert!(
                scoped_token(Exchange {
                    expires_in,
                    ..exchange()
                })
                .is_err()
            );
        }
        for scope in ["repository:hexpm", "package:hexpm/another"] {
            assert!(
                scoped_token(Exchange {
                    scope: scope.to_owned(),
                    ..exchange()
                })
                .is_err()
            );
        }
        for access_token in ["", "token\nheader", "Bearer fixture"] {
            assert!(
                scoped_token(Exchange {
                    access_token: access_token.to_owned(),
                    ..exchange()
                })
                .is_err()
            );
        }
        assert!(!valid_token(&"x".repeat(TOKEN_LIMIT + 1)));
    }

    #[test]
    fn oidc_request_cannot_send_its_bearer_to_another_origin() {
        assert!(
            request_url("https://run.actions.githubusercontent.com/token?api-version=2").is_ok()
        );
        for url in [
            "http://run.actions.githubusercontent.com/token",
            "https://actions.githubusercontent.com.attacker.invalid/token",
            "https://user@run.actions.githubusercontent.com/token",
            "https://run.actions.githubusercontent.com:444/token",
            "https://run.actions.githubusercontent.com/token#fragment",
        ] {
            assert!(request_url(url).is_err());
        }
    }

    #[test]
    fn confirmation_and_missing_authentication_never_launch_gleam() {
        assert!(complete(Mode::Check, Some(Token("fixture".to_owned()))).is_ok());
        assert!(complete(Mode::Check, None).is_err());
        assert!(complete(Mode::Publish, None).is_err());
    }
}
