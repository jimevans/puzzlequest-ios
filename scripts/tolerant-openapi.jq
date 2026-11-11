# Makes the API's published description generate a Swift client that reads
# every version 1 response: swift-openapi-generator turns some of what the
# description says into stricter or lossier code than the API's promises
# (decision 0023 in the server repository) allow. scripts/update-api.sh runs
# this on the pinned release's openapi.json. (Since 1.0.1 the description
# itself leaves responses open to new fields, so they need no change here.)
#
# - Each enumeration under `components` (the shapes responses use) becomes the
#   generator's documented "open enum": anyOf the known values and any string,
#   so a value added later decodes as a plain string instead of failing.
#   Enumerations written inline in request bodies stay closed: they're values
#   the app sends, and the server accepts every one it lists.
# - A property that may be null (`anyOf: [X, {type: "null"}]`, the API's "not
#   set") becomes X and is no longer required. The generator doesn't support
#   the null alternative and would leave the whole property out; as an
#   optional property, null and absent both decode as nil.

def open_enum:
  if type == "object" and .type == "string" and has("enum") then
    with_entries(select(.key != "type" and .key != "enum"))
    + { anyOf: [ { type: "string", enum: .enum }, { type: "string" } ] }
  else . end;

def is_nullable:
  type == "object" and (.anyOf | type) == "array"
  and any(.anyOf[]; . == { type: "null" });

def without_null:
  (.anyOf | map(select(. != { type: "null" }))) as $rest
  | del(.anyOf)
  + (if ($rest | length) == 1 then $rest[0] else { anyOf: $rest } end);

def optional_when_nullable:
  if type == "object" and (.properties | type) == "object" then
    [.properties | to_entries[] | select(.value | is_nullable) | .key] as $nullable
    | .properties |= with_entries(
        if (.key | IN($nullable[])) then .value |= without_null else . end)
    | if has("required")
      then .required |= map(select(IN($nullable[]) | not))
      else . end
  else . end;

.components.schemas |= map_values(walk(open_enum))
| walk(optional_when_nullable)
