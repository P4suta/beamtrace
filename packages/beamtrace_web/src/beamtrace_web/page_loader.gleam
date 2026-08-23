// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/page
import beamtrace_web/workspace
import lustre/effect.{type Effect}

@external(javascript, "./page_loader_ffi.mjs", "pageUrl")
pub fn url(start: Int, limit: Int, query: String) -> String

pub fn load(start: Int, limit: Int, query: String) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    fetch_page(
      start,
      limit,
      query,
      fn(body) {
        case page.decode(body) {
          Ok(page) -> dispatch(workspace.PageLoaded(query, page))
          Error(reason) -> dispatch(workspace.PageLoadFailed(query, reason))
        }
      },
      fn(reason) { dispatch(workspace.PageLoadFailed(query, reason)) },
    )
  })
}

@external(javascript, "./page_loader_ffi.mjs", "fetchPage")
fn fetch_page(
  start: Int,
  limit: Int,
  query: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil
