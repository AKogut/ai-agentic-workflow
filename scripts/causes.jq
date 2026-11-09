# Why a workflow run failed, from the text of its failed jobs. Every signature
# here was read off a real failure, and scripts/run-cause.sh supplies the text.
# Input: {jobs: [{errors: [line], log: text or null}]}, where errors are the
# job's failure annotations and ##[error] lines, and log is the end of its log,
# or null when it was not read. Output: {kind, signature}, the signature's name
# and never the text, because a log is untrusted and must not reach a report.
#
#   credentials  GitHub refused a token: a retry cannot fix it
#   infra        the runner or the toolchain failed: a retry can clear it
#   external     a service outside the repository failed
#   unknown      nothing here explains it, which is the default
#
# A signature on `errors` is anchored, because a test suite can log the same
# words: restful-booker's own API answers "Bad credentials" to a wrong password.
def signatures: [
  # flakemetry release, 41462782379: changesets/action with RELEASE_PAT.
  {name: "github-bad-credentials", kind: "credentials", in: "errors",
   pattern: "^Bad credentials - https://docs\\.github\\.com/rest"},
  # flakemetry release, 41840530609 and 42602775016: the workflow's own check of
  # RELEASE_PAT. Only a 401: any other status says nothing about the token.
  {name: "release-token-rejected", kind: "credentials", in: "errors",
   pattern: "^GitHub answered 401\\. No version pull request can open until it is rotated"},
  # mobile Appium E2E, 41474808279: android-emulator-runner gave up.
  {name: "android-emulator-boot-timeout", kind: "infra", in: "errors",
   pattern: "^Timeout waiting for emulator to boot\\.$"},
  # mobile Nightly E2E, 41457905719: sdkmanager got a broken system image.
  {name: "android-sdk-corrupt-download", kind: "infra", in: "log",
   pattern: "An error occurred while preparing SDK package .*: Error reading Zip content"},
  # ephemeral Ephemeral environment, 41308918930: one image of five did not load
  # into the kind node, and the other cluster jobs on that commit passed.
  {name: "kind-image-not-loaded", kind: "infra", in: "errors",
   pattern: " is not in the image store of [a-z0-9-]+$"},
  # ephemeral Ephemeral environment, 36865479607 and 36865383596: quay.io refused
  # a pull for a whole batch of runs on 1 Oct.
  {name: "registry-pull-refused", kind: "external", in: "log",
   pattern: "docker: Error response from daemon: unauthorized: access to the requested resource is not authorized"},
  # restful Report, 41429170737: the live demo answered 500 until the wait ran out.
  {name: "live-platform-not-ready", kind: "external", in: "log",
   pattern: "Restful Booker Platform is not ready after [0-9]+ attempts"},
  # mobile Nightly E2E, 42468767207: the Gradle wrapper got a 504 from Gradle's
  # distribution server. Only a 5xx: a wrong version answers 404, and that is a bug.
  {name: "gradle-download-5xx", kind: "external", in: "errors",
   pattern: "^Exception in thread \"main\" java\\.io\\.IOException: Server returned HTTP response code: 5[0-9]{2} for URL: https://services\\.gradle\\.org/"},
  # mobile Nightly E2E, 42468767207 (ruby/setup-ruby), and restful Performance,
  # 42476973322 (grafana/setup-k6): a release download still answered 504 after
  # the action's own retries.
  {name: "tool-download-5xx", kind: "external", in: "errors",
   pattern: "^(Error: )?Unexpected HTTP response: 5[0-9]{2}$"},
  # ephemeral Ephemeral environment, 42583637532 and 42583153204: helm/kind-action
  # downloaded something other than the binary or its checksum file.
  {name: "kind-download-corrupt", kind: "external", in: "log",
   pattern: "kind-linux-[a-z0-9]+: FAILED|sha256sum: 'standard input': no properly formatted checksum lines found"}
];

def job_cause:
  . as $job
  | ([signatures[] | . as $s
      | select(if $s.in == "errors" then any($job.errors[]?; test($s.pattern))
               else ($job.log // "" | test($s.pattern)) end)][0]) as $hit
  | if $hit then {kind: $hit.kind, signature: $hit.name} else {kind: "unknown", signature: null} end;

# A run is only as explained as its least explained job, so one job with a real
# failure next to one that lost its emulator is unknown, and no retry leans on
# it. A refused token outranks that, because no retry can pass it.
def rank: {credentials: 0, unknown: 1, external: 2, infra: 3}[.kind];

[(.jobs // [])[] | job_cause] | sort_by(rank) | .[0] // {kind: "unknown", signature: null}
