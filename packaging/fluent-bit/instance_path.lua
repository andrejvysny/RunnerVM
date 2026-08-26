-- Lifts `instance_id` and `stream` out of the tailed path for per-instance logs.
-- `file` looks like "<state-dir>/logs/instances/<instance-id>/serial.log".
function split_instance_path(tag, timestamp, record)
  local path = record["file"]
  if path == nil then return 0, timestamp, record end
  local instance, name = string.match(path, "/instances/([^/]+)/([^/]+)%.log$")
  if instance == nil then return 0, timestamp, record end
  record["instance_id"] = instance
  record["stream"] = name
  return 2, timestamp, record
end
