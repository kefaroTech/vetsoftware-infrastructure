output "schedule_names" {
  value = sort([for schedule in aws_scheduler_schedule.this : schedule.name])
}
