#!/bin/bash
# install-cursor.sh - Friendlier name for sync-cursor-skill.sh.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/sync-cursor-skill.sh" "$@"
