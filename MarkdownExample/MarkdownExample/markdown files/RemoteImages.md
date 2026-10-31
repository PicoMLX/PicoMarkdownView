# Remote Images

This sample exercises remote Markdown image loading in `PicoMarkdownView`. On macOS, click a standalone image to open the example app's lightbox. Zoom and pan there, copy or save the image, and press Escape to close it. Dragging across images still selects the underlying Markdown. The image mixed with text below keeps its inline rendering.

## HTTPS image

![HTTPS image from httpbin](https://httpbin.org/image/png)

## HTTP image (ATS exception required in the example app)

![HTTP image from httpbin](http://httpbin.org/image/png)

## Mixed inline text + image

Before ![small demo image](https://httpbin.org/image/jpeg) after.
