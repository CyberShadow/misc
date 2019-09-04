/**
   Time and print difference between vsync times of several monitors.
   Assumes all monitors are running at the same refresh rate.
   Specify some coordinate within each monitor to be tested on the command line.
   E.g. (with three monitors): ./measure_monitor_sync 0x0 1920x0 3840x0
   Output is % difference from the first, one line for each additional monitor.
 */

// g++ -o X11Window X11.cpp -lX11 -lGL -lGLEW -L/usr/X11/lib -I/opt/X11/include
#include <cstdio>
#include <cstring>
#include <cstdlib>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysymdef.h>

#include <GL/gl.h>
#include <GL/glx.h>

#include <sys/time.h>
#include <unistd.h>

#include <pthread.h>

#include <atomic>

#define WINDOW_WIDTH	64
#define WINDOW_HEIGHT	64
#define MAX_WINDOWS 16

// Keep running until we see the sync difference
// (rounded/pigeonholed to NUM_VBLANK_SLOTS slots)
// at least SLOT_CONFIDENCE times for each window.
#define NUM_VBLANK_SLOTS 100
#define SLOT_CONFIDENCE 50

typedef GLXContext (*glXCreateContextAttribsARBProc)(Display*, GLXFBConfig, GLXContext, Bool, const int*);

// static double GetMilliseconds() {
// 	static timeval s_tTimeVal;
// 	gettimeofday(&s_tTimeVal, NULL);
// 	double time = s_tTimeVal.tv_sec * 1000.0; // sec to ms
// 	time += s_tTimeVal.tv_usec / 1000.0; // us to ms
// 	return time;
// }

int numWindows;

struct TestWindow
{
	TestWindow()
		: display(NULL)
		, window(0)
		, windowAttribs()
		, visual(NULL)
		, context(0)
	{}

	void run(int index, int x, int y)
	{
		this->index = index;
		create(x, y);
		if (pthread_create(&thread, NULL, &threadFunc, this))
			throw "Thread creation failed";
	}

	void wait()
	{
		pthread_join(thread, NULL);
	}

	~TestWindow()
	{
		if (context)
			glXDestroyContext(display, context);
		if (visual)
			XFree(visual);
		if (windowAttribs.colormap)
			XFreeColormap(display, windowAttribs.colormap);
		if (window)
			XDestroyWindow(display, window);
		if (display)
			XCloseDisplay(display);
	}

private:
	pthread_t thread;

	static void* threadFunc(void* arg)
	{
		((TestWindow*)arg)->runLoop();
		return NULL;
	}

	static long long ll(const struct timespec& tv)
	{
		return (long long)tv.tv_sec * 1000 * 1000 * 1000 + tv.tv_nsec;
	}

	static long long clock_gettime_ll()
	{
		struct timespec t;
		clock_gettime(CLOCK_MONOTONIC_RAW, &t);
		return ll(t);
	}

	void runLoop()
	{
		// Start-up phase.

		static std::atomic_int numStarted(0);
		static std::atomic_bool allStarted(false);

		while (true)
		{
			render();
			if (index == 0)
			{
				int old = numStarted.exchange(1);
				if (old == numWindows)
				{
					allStarted = true;
					break;
				}
			}
			else
			{
				numStarted++;
				if (allStarted.load())
					break;
			}
		}
#ifdef DEBUG
		fprintf(stderr, "Window %d started!\n", index);
#endif

		/*
		static struct timespec times[MAX_WINDOWS];
		render();
		clock_gettime(CLOCK_MONOTONIC_RAW, &times[index]);
		if (index == 0)
		{
			render();
			struct timespec main;
			clock_gettime(CLOCK_MONOTONIC_RAW, &main);
			render();
			long long dur = ll(main) - ll(times[0]);
			for (int w = 1; w < numWindows; w++)
			{
				if (!ll(times[0]))
					printf("NOT READY\n");
				long long ofs = ll(times[w]) - ll(times[0]);
				ofs = (ofs + dur * 10) % dur;
				printf("Window %d: %lld/%lld (%d%%)\n",
					w, ofs, dur, 100 * ofs / dur);
			}
		}
		*/

		static std::atomic_int64_t times[MAX_WINDOWS];
		times[index] = clock_gettime_ll();
		render();
		int resultCounts[MAX_WINDOWS][NUM_VBLANK_SLOTS] = {0};

		static std::atomic_bool done(false);
		while (!done)
		{
			if (index == 0)
			{
				long long now = clock_gettime_ll();
				long long old = times[0].exchange(now);
				long long dur = now - old;
				int numComplete = 1;
				int slots[MAX_WINDOWS];
				for (int w = 1; w < numWindows; w++)
				{
					long long ofs = times[w] - old;
					ofs = (ofs + dur * 10) % dur;
					ofs = dur - ofs; // x=1-x
#ifdef DEBUG
					fprintf(stderr, "Window %d: %lld/%lld (%lld%%)\n",
						w, ofs, dur, 100 * ofs / dur);
#endif
					int slot = slots[w] = NUM_VBLANK_SLOTS * ofs / dur;
					if (++resultCounts[w][slot] >= SLOT_CONFIDENCE)
						numComplete++;
				}
				if (numComplete == numWindows)
				{
					done = true;
					for (int w = 1; w < numWindows; w++)
						printf("%d\n", slots[w]);
					return;
				}
			}
			else
				times[index] = clock_gettime_ll();
			render();
		}
	}

	int index;
	Display* display;
	Window window;
	Screen* screen;
	int screenId;
	XSetWindowAttributes windowAttribs;
	XVisualInfo* visual;
	GLXContext context;
	Atom atomWmDeleteWindow;

	void create(int x, int y)
	{
		// Open the display
		display = XOpenDisplay(NULL);
		if (display == NULL)
			throw "Could not open display";

		screen = DefaultScreenOfDisplay(display);
		screenId = DefaultScreen(display);

		// Check GLX version
		GLint majorGLX, minorGLX = 0;
		glXQueryVersion(display, &majorGLX, &minorGLX);
		if (majorGLX <= 1 && minorGLX < 2)
			throw "GLX 1.2 or greater is required";

		GLint glxAttribs[] = {
			GLX_X_RENDERABLE    , True,
			GLX_DRAWABLE_TYPE   , GLX_WINDOW_BIT,
			GLX_RENDER_TYPE     , GLX_RGBA_BIT,
			GLX_X_VISUAL_TYPE   , GLX_TRUE_COLOR,
			GLX_RED_SIZE        , 8,
			GLX_GREEN_SIZE      , 8,
			GLX_BLUE_SIZE       , 8,
			GLX_ALPHA_SIZE      , 8,
			GLX_DEPTH_SIZE      , 24,
			GLX_STENCIL_SIZE    , 8,
			GLX_DOUBLEBUFFER    , True,
			None
		};

		int fbcount;
		GLXFBConfig* fbc = glXChooseFBConfig(display, screenId, glxAttribs, &fbcount);
		if (fbc == 0)
			throw "Failed to retrieve framebuffer";

		// Pick the FB config/visual with the most samples per pixel
		int best_fbc = -1, worst_fbc = -1, best_num_samp = -1, worst_num_samp = 999;
		for (int i = 0; i < fbcount; ++i) {
			XVisualInfo *vi = glXGetVisualFromFBConfig( display, fbc[i] );
			if ( vi != 0) {
				int samp_buf, samples;
				glXGetFBConfigAttrib( display, fbc[i], GLX_SAMPLE_BUFFERS, &samp_buf );
				glXGetFBConfigAttrib( display, fbc[i], GLX_SAMPLES       , &samples  );

				if ( best_fbc < 0 || (samp_buf && samples > best_num_samp) ) {
					best_fbc = i;
					best_num_samp = samples;
				}
				if ( worst_fbc < 0 || !samp_buf || samples < worst_num_samp )
					worst_fbc = i;
				worst_num_samp = samples;
			}
			XFree( vi );
		}
		GLXFBConfig bestFbc = fbc[ best_fbc ];
		XFree( fbc ); // Make sure to free this!

		visual = glXGetVisualFromFBConfig( display, bestFbc );
		if (visual == NULL)
			throw "Could not create correct visual window";

		if (screenId != visual->screen) {
			fprintf(stderr, "screenId(%d) does not match visual->screen(%d).\n",
				screenId, visual->screen);
			throw "Visual mismatch";
		}

		// Open the window
		windowAttribs.border_pixel = BlackPixel(display, screenId);
		windowAttribs.background_pixel = WhitePixel(display, screenId);
		windowAttribs.override_redirect = True;
		windowAttribs.colormap = XCreateColormap(display, RootWindow(display, screenId), visual->visual, AllocNone);
		windowAttribs.event_mask = ExposureMask;
		window = XCreateWindow(display, RootWindow(display, screenId), x, y, WINDOW_WIDTH, WINDOW_HEIGHT, 0, visual->depth, InputOutput, visual->visual, CWBackPixel | CWColormap | CWBorderPixel | CWEventMask | CWOverrideRedirect, &windowAttribs);

		// Redirect Close
		atomWmDeleteWindow = XInternAtom(display, "WM_DELETE_WINDOW", False);
		XSetWMProtocols(display, window, &atomWmDeleteWindow, 1);

		// Create GLX OpenGL context
		glXCreateContextAttribsARBProc glXCreateContextAttribsARB = 0;
		glXCreateContextAttribsARB = (glXCreateContextAttribsARBProc) glXGetProcAddressARB( (const GLubyte *) "glXCreateContextAttribsARB" );

		int context_attribs[] = {
			GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
			GLX_CONTEXT_MINOR_VERSION_ARB, 2,
			GLX_CONTEXT_FLAGS_ARB, GLX_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB,
			None
		};

		const char *glxExts = glXQueryExtensionsString( display,  screenId );
		if (!isExtensionSupported( glxExts, "GLX_ARB_create_context")) {
			fprintf(stderr, "GLX_ARB_create_context not supported\n");
			context = glXCreateNewContext( display, bestFbc, GLX_RGBA_TYPE, 0, True );
		}
		else {
			context = glXCreateContextAttribsARB( display, bestFbc, 0, true, context_attribs );
		}
		XSync( display, False );

		// Verifying that context is a direct context
		if (!glXIsDirect (display, context)) {
#ifdef DEBUG
			fprintf(stderr, "Indirect GLX rendering context obtained\n");
#endif
		}
		else {
#ifdef DEBUG
			fprintf(stderr, "Direct GLX rendering context obtained\n");
#endif
		}
		glXMakeCurrent(display, window, context);

#ifdef DEBUG
		fprintf(stderr, "GL Renderer: %s\n", glGetString(GL_RENDERER));
		fprintf(stderr, "GL Version: %s\n", glGetString(GL_VERSION));
		fprintf(stderr, "GLSL Version: %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));
#endif

		glClearColor(0.5f, 0.6f, 0.7f, 1.0f);
		glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);

		// Show the window
		XClearWindow(display, window);
		XMapRaised(display, window);
	}

	int frame = 0;
	bool render()
	{
		XEvent ev;
		if (XPending(display) > 0) {
			XNextEvent(display, &ev);
			if (ev.type == Expose) {
				XWindowAttributes attribs;
				XGetWindowAttributes(display, window, &attribs);
				glViewport(0, 0, attribs.width, attribs.height);
			}
			if (ev.type == ClientMessage) {
				if ((Atom)ev.xclient.data.l[0] == atomWmDeleteWindow) {
					return true;
				}
			}
			else if (ev.type == DestroyNotify) { 
				return true;
			}
		}

#ifdef DEBUG
		fprintf(stderr, "%d: %d\n", index, frame++);
#endif
		glClear(GL_COLOR_BUFFER_BIT);
		glXSwapBuffers(display, window);
		return false;
	}

	static bool isExtensionSupported(const char *extList, const char *extension)
	{
		return strstr(extList, extension) != 0;
	}
};

int main(int argc, char** argv)
{
	TestWindow windows[MAX_WINDOWS];
	numWindows = argc - 1;

	for (int i = 0; i < numWindows ; i++) {
		int x = atoi(strtok(argv[1+i], "x"));
		int y = atoi(strtok(NULL     , "x"));
		//windows[i].create(x, y);
		windows[i].run(i, x, y);
	}

	// double prevTime = GetMilliseconds();
	// double currentTime = GetMilliseconds();
	// double deltaTime = 0.0;

	// timeval time;
	// long sleepTime = 0;
	// gettimeofday(&time, NULL);
	// long nextGameTick = (time.tv_sec * 1000) + (time.tv_usec / 1000);

	// Enter message loop
	// while (true) {
	// 	for (int i = 0; i < numWindows ; i++)
	// 		if (windows[i].render())
	// 			return 1;
	// }

	for (int i = 0; i < numWindows ; i++)
		windows[i].wait();
#ifdef DEBUG
	fprintf(stderr, "Shutting Down\n");
#endif

	return 0;
}
