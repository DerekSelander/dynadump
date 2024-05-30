# dynadump

Yet another Objective-C class-dump CLI tool

## Why?

For fun. I got burnt out on the complexity of `dsdump` trying to grab all of Apple's dyld/objc4 opensource code and compiling it. This attempts to class-dump ObjC code via mostly public or unlikely to change private APIs

## Features
```
  dynadump (built: May 30 2024, 00:59:46) - yet another class-dump done via dlopen & exception catching

	Parameters:
	list                list all the dylibs in the dyld shared cache (dsc)
	list  $DYLIB        list all the objc classes in a dylib $DYLIB
	dump  $DYLIB        dump all the ObjC classes found in a dylib on disk
	dump  $DYLIB $CLASS dump a specific ObjC class found in dylib $DYLIB
	sig   $SIGSTR       prints the demangled objc signature
	sign  $DYLIB        attempts to sign a dylib in place
	list  $DYLIB $CLASS Same cmd as above (convenience for listing then dumping)

	Environment Variables:
	NOCOLOR - Forces no color, color will be on by default unless piped
	COLOR   - Forces color, regardless of stdout destination
	VERBOSE - Verbose output
	NOEXC   - Don't use an exception handler (on in x86_64)
	DEBUG   - Used internally to hunt down f ups
```


The following example looks for any images in the dsc with `Shaz`, which can display a numerical number to print for `list`ing or `dump`ing. You can dump every ObjC class in the module or just a specific class. Use the **`VERBOSE`** flag to provide more detail, like load addresses or offsets.
<img width="1402" alt="screenshot" src="https://github.com/DerekSelander/dynadump/assets/1037191/7d18a258-fb6f-4044-bc67-cafbad641d55">

If the color hurts the eyes, a `NOCOLOR` environment variable can calm it down.

<img width="1402" alt="screenshot2" src="https://github.com/DerekSelander/dynadump/assets/1037191/d58f2b51-b6a3-481f-8f44-575ccd36fae8">


### Neat/bad design choices

Since this loads an image through `dlopen`, one has to be careful to prevent the image constructors from doing something bad, like crashing the program (I am looking at you, `/S*/L*/PrivateFrameworks/SpringBoard.framework`). To get around this, exception handlers are created on all callouts to load addresses. So when an image loads, an exception (a breakpoint) is hit and the exception handler steps over the code. This will prevent all constructors from executing for good or for bad. If you see something not working try using the **`NOEXC=1`** to prevent exception handlers from being setup

The other shitty consequence of this design is that `dlopen` really is limited to dylibs and not standalone executables. In addition, a platform could be for iOS while being opened for Mac Catalyst. To deal with this, after `dlopen` fails for the first time, `dynadump` will copy the image of interest and patch the needed commands needed to be able to `dlopen`. This gets more fun when dealing with things like `LC_RPATH`.
