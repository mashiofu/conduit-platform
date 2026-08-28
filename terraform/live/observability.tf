# CloudWatch Logs Insights saved queries against the log group the EKS
# "Amazon CloudWatch Observability" addon ships container stdout to
# (/aws/containerinsights/<cluster>/application - see modules/eks's
# cloudwatch_observability addon). Starting points for triage, not
# polished reports - the Gin access-log regex below assumes latency is
# rendered in "ms" (true for most real request latencies; very fast or
# very slow requests render in µs/s instead and won't match).

locals {
  container_insights_log_group = "/aws/containerinsights/${module.eks.cluster_name}/application"
}

resource "aws_cloudwatch_query_definition" "backend_5xx" {
  name            = "${local.name_prefix}/backend-5xx-responses"
  log_group_names = [local.container_insights_log_group]
  query_string    = <<-EOT
    fields @timestamp, @message
    | filter kubernetes.container_name = "conduit-backend"
    | parse @message /\| (?<status>\d{3}) \|\s*(?<latency>[\d.]+\w+) \|.*\| (?<method>\S+)\s+"(?<path>[^"]+)"/
    | filter status like /^5/
    | sort @timestamp desc
    | limit 100
  EOT
}

resource "aws_cloudwatch_query_definition" "backend_status_distribution" {
  name            = "${local.name_prefix}/backend-status-code-distribution"
  log_group_names = [local.container_insights_log_group]
  query_string    = <<-EOT
    fields @timestamp, @message
    | filter kubernetes.container_name = "conduit-backend"
    | parse @message /\| (?<status>\d{3}) \|/
    | stats count(*) as request_count by status
    | sort request_count desc
  EOT
}

resource "aws_cloudwatch_query_definition" "backend_slow_requests" {
  name            = "${local.name_prefix}/backend-slow-requests-over-500ms"
  log_group_names = [local.container_insights_log_group]
  query_string    = <<-EOT
    fields @timestamp, @message
    | filter kubernetes.container_name = "conduit-backend"
    | parse @message /\| (?<status>\d{3}) \|\s*(?<latency_ms>[\d.]+)ms \|.*\| (?<method>\S+)\s+"(?<path>[^"]+)"/
    | filter latency_ms > 500
    | sort latency_ms desc
    | limit 100
  EOT
}

resource "aws_cloudwatch_query_definition" "errors_across_all_pods" {
  name            = "${local.name_prefix}/errors-across-all-pods"
  log_group_names = [local.container_insights_log_group]
  query_string    = <<-EOT
    fields @timestamp, kubernetes.pod_name, kubernetes.container_name, @message
    | filter @message like /(?i)(error|panic|fatal)/
    | sort @timestamp desc
    | limit 100
  EOT
}
