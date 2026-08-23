// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/s3_blob
import gleeunit/should

pub fn sigv4_matches_the_official_s3_get_object_example_test() {
  s3_blob.authorization_for_test(
    method: "GET",
    canonical_uri: "/test.txt",
    host: "examplebucket.s3.amazonaws.com",
    region: "us-east-1",
    access_key: "AKIAIOSFODNN7EXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    amz_date: "20130524T000000Z",
    additional_headers: [#("range", "bytes=0-9")],
    payload: "",
  )
  |> should.equal(
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
  )
}

pub fn s3_backend_accepts_only_https_and_bounded_path_style_configuration_test() {
  blob_store.s3(
    endpoint: "https://objects.example:9443",
    bucket: "beamtrace-prod",
    region: "ap-northeast-1",
    prefix: "captures/team-a",
  )
  |> should.be_ok()
  blob_store.s3(
    endpoint: "http://objects.example",
    bucket: "beamtrace-prod",
    region: "ap-northeast-1",
    prefix: "captures",
  )
  |> should.equal(Error("invalid_s3_config"))
  blob_store.s3(
    endpoint: "https://objects.example",
    bucket: "../escape",
    region: "ap-northeast-1",
    prefix: "captures",
  )
  |> should.equal(Error("invalid_s3_config"))
}
