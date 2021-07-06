output "instance_id" {
    description = "Instance ID of NAT64/DNS64 host"
    value       = "${aws_instance.nat64_node.id}"
}

output "ipv6_address" {
    description = "IPv6 address of NAT64/DNS64 instance"
    value       = "${element(element(aws_instance.nat64_node.*.ipv6_addresses, 0), 0)}"
}

output "security_group_id" {
    description = "Security group ID for NAT64/DNS64 instance"
    value       = "${aws_security_group.nat64_security_group.id}"
}