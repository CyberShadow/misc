#!/bin/sh
test -f $GIT_DIR/GITGUI_MSG && ! grep -vqE '^[a-z0-9._]+:$' $GIT_DIR/GITGUI_MSG && rm $GIT_DIR/GITGUI_MSG
( test -s $GIT_DIR/COMMIT_EDITMSG ) || (
	git status --porcelain | git-prepare-commit-msg > "$1"
)
