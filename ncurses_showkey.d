#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
 dependency "ncurses" version="==1.0.0"
+/

/**
   Show the ncurses codes and names of pressed keys.
*/

import std.stdio : writefln;
import deimos.ncurses;

void main()
{
    int ch;

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, true);

	while (true)
	{
		ch = getch();
		mvprintw(0, 0, "The key pressed is: %d / %s          ", ch, keyname(ch));
	}

    // endwin();
}
