output "instance_id" {
  value = aws_instance.llm_host.id
}

output "private_ip" {
  value       = aws_instance.llm_host.private_ip
  description = "Reach the chat UI at https://<this-ip> from an allowed CIDR, or connect via SSM Session Manager for shell access"
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
