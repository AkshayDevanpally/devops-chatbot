output "public_ip" { value = data.aws_instance.node.public_ip }
output "instance_id" { value = local.instance_id }
output "instance_type" { value = data.aws_instance.node.instance_type }
output "zone" { value = data.aws_instance.node.availability_zone }
output "market" { value = var.spot ? "spot" : "on-demand" }
