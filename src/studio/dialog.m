#import <AppKit/AppKit.h>
#include <string.h>
int voice_save_path(char *out,size_t size) {NSSavePanel *p=[NSSavePanel savePanel];p.nameFieldStringValue=@"voice.wav";if([p runModal]!=NSModalResponseOK)return 0;const char *s=p.URL.fileSystemRepresentation;if(strlen(s)>=size)return -1;strcpy(out,s);return 1;}
