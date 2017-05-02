output "Mesos Master Public IP" {
  value = ["${aws_instance.master.*.public_ip}"]
}

output "Private Agent Public IP Address" {
  value = ["${aws_instance.agent.*.public_ip}"]
}

output "Public Agent Public IP Address" {
  value = ["${aws_instance.public-agent.*.public_ip}"]
}

output "master_ids" {
  value = ["${aws_instance.master.*.id}"]
}

output "agent_ids" {
  value = ["${aws_instance.agent.*.id}"]
}

output "public_agent_ids" {
  value = ["${aws_instance.public-agent.*.id}"]
}
