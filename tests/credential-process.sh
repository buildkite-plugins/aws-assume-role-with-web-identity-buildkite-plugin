#!/bin/bash

# Stand-in credential_process script for tests. The plugin only writes an AWS
# config pointing at this path; it never executes the script itself.
echo '{"Version": 1}'
