package authz

# C5 policy: allow everything except tool2.
#
# Single-backend setup — no mcp_router in the chain means no server1__ prefix is added.
# OPA reads the plain tool name ("tool2", not "server1__tool2") from the same
# envoy.filters.http.mcp metadata namespace that C2 uses.
#
# Same metadata path as C2:
#   input.attributes.metadataContext.filterMetadata["envoy.filters.http.mcp"]["params"]["name"]

default allow := false

# Non-tool-call requests pass through unconditionally.
allow if {
    not is_tools_call
}

# tools/call: allow unless blocked.
allow if {
    is_tools_call
    not blocked_tool
}

is_tools_call if {
    input.attributes.metadataContext.filterMetadata["envoy.filters.http.mcp"]["method"] == "tools/call"
}

# tool2 is blocked — plain name, no prefix.
blocked_tool if {
    input.attributes.metadataContext.filterMetadata["envoy.filters.http.mcp"]["params"]["name"] == "tool2"
}
