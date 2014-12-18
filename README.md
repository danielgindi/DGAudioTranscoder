DGAudioTranscoder
=================

An audio transcoding module - takes any source format, transcodes to any codec available on iOS/OSX.

You can initialize the module with any URL, from an HTTP/S source, or a local file (file:///).

You give it an output url (local file) and you're good to go!

Features
---
* HTTP and HTTPS sources
* Local file (file:///) sources
* Streams the data, not caching locally
* Specify the native codec that you want to use
* Automatically retains the sample rate and number of channels from the source stream
* A getter property for progress (When there's a Content-Length or a local file)
* Receive status updates through a delegate or blocks
* Ability to reconnect to HTTP/S source after a network hiccup, and continue where it left

Usage of this library is allowed only when attributed to the author in the licenses section of your application.


## Me
* Hi! I am Daniel Cohen Gindi. Or in short- Daniel.
* danielgindi@gmail.com is my email address.
* That's all you need to know.

## Help

If you like what you see here, and want to support the work being done in this repository, you could:
* Actually code, and issue pull requests
* Spread the word
* 
[![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=CHRDHZE79YTMQ)

## License

All the code here is under MIT license. Which means you could do virtually anything with the code.
I will appreciate it very much if you keep an attribution where appropriate.

    The MIT License (MIT)
    
    Copyright (c) 2013 Daniel Cohen Gindi (danielgindi@gmail.com)
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
