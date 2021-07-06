# ==================================================
# Outputs
# ==================================================
# ==================================================

output "primary_cluster_fqdn" {
  description = "Primary cluster DNS address"
  value       = aws_route53_record.primary_master_ns_main_record.fqdn
}

output "secondary_cluster_fqdn" {
  description = "Secondary cluster DNS address"
  value       = aws_route53_record.secondary_master_ns_main_record.fqdn
}