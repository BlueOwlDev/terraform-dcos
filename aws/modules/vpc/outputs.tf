# The following outputs are required for remote state to work
# with the DC/OS terraform module.
output "vpc_id" {
  value = "${aws_vpc.main.id}"
}

output "cidr_block" {
  value = "${aws_vpc.main.cidr_block}"
}

output "public_subnet_ids" {
  value = "${aws_subnet.public*.id}"
}

output "private_subnet_ids" {
  value = "${aws_subnet.private*.id}"
}
