/**
   Build a D program (in release mode) and run it.

   This is a program (and not e.g. a shell script) only because
   Windows treats batch files or shell scripts very differently from
   executable programs.
*/

import drunner;

int main(string[] args)
{
	return drun("dbuildr", args);
}
