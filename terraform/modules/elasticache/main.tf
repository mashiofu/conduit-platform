resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-redis"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "Redis access for ${var.name_prefix}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-redis-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "from_app" {
  for_each                     = var.allowed_security_group_ids
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = each.value
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Redis from ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.redis.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Unlike RDS's enabled_cloudwatch_logs_exports (which just points at a
# self-managed log group), ElastiCache requires the destination log group
# to already exist - so this has to be declared explicitly here.
resource "aws_cloudwatch_log_group" "redis_slow_log" {
  name              = "/aws/elasticache/${var.name_prefix}-redis/slow-log"
  retention_in_days = 14
  tags              = var.tags
}

# Single node, no replication group. This cache is a performance
# optimization for anonymous GET responses (see the backend's cache
# middleware), never a source of truth - on a cache miss or an outright
# outage, the app falls straight back to Postgres and stays correct, just
# slower. That makes a multi-node replication group's cost/complexity hard
# to justify here; revisit if cache availability ever becomes load-bearing
# rather than a latency optimization.
resource "aws_elasticache_cluster" "this" {
  cluster_id         = "${var.name_prefix}-redis"
  engine             = "redis"
  engine_version     = var.engine_version
  node_type          = var.node_type
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]
  apply_immediately  = true

  # Slow-log specifically (not engine-log too) - this tier's operationally
  # relevant log is "what was slow," which ties directly into the cache
  # hit-rate story already in Grafana; engine-log is mostly startup/
  # shutdown noise that isn't worth the extra log volume on a dev cluster.
  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_slow_log.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}
