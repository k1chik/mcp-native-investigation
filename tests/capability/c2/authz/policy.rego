package authz

# C2 policy: allow everything except server1__tool2.
#
# This policy reads the tool name from Envoy's dynamic metadata namespace
# "envoy.filters.http.mcp", which mcp_filter populates from the JSON-RPC body.
# The key claim being tested: OPA can authorize by MCP tool name using only
# the metadata Envoy provides - no ext-proc header injection needed.
#
# How the metadata arrives here:
#   mcp_filter writes -> dynamic metadata["envoy.filters.http.mcp"]["params"]["name"]
#   ext_authz reads   -> CheckRequest.attributes.metadataContext.filterMetadata
#                        (because metadata_context_namespaces includes that namespace)
#   OPA sees          -> input.attributes.metadataContext.filterMetadata
#                          ["envoy.filters.http.mcp"]["params"]["name"]
#
# Note: protojson marshaling uses camelCase field names (metadataContext, filterMetadata).
# The tool name is at params.name (the raw JSON-RPC params), not a flat "tool_name" field.

default allow := false

# Non-tool-call requests (initialize, tools/list, ping, etc.) have a different
# method in the metadata. Allow them unconditionally.
allow if {
    not is_tools_call
}

# tools/call requests: allow unless the tool is blocked.
allow if {
    is_tools_call
    not blocked_tool
}

is_tools_call if {
    input.attributes.metadataContext.filterMetadata["envoy.filters.http.mcp"]["method"] == "tools/call"
}

# server1__tool2 is the test-blocked tool for C2.
# OPA reads the tool name from params.name in the MCP metadata - no header needed.
blocked_tool if {
    input.attributes.metadataContext.filterMetadata["envoy.filters.http.mcp"]["params"]["name"] == "server1__tool2"
}
