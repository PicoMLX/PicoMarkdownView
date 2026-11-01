# OpenUI

Interactive cards, forms, a date picker, and a read-only summary share this document with ordinary Markdown. Each card keeps its own local state while you scroll through the surrounding text.

## Plan a weekend

This paragraph is native Markdown. Choose Stream and Replay to watch the form arrive. The form appears when its OpenUI fence completes. Enter your name and choose **Plan trip** to see the action above the document.

```openui
root = Stack([card])
card = Card([heading, tripForm])
heading = CardHeader("Plan a weekend", "Official OpenUI components inside the native Markdown document")
tripForm = Form("trip", buttons, [travelerField, emailField])
travelerField = FormControl("Traveler", Input("traveler", "Your name", "text", {required: true, minLength: 2}), "Who is travelling?")
emailField = FormControl("Email", Input("email", "you@example.com", "email", {required: true, email: true}), "Included only in the action callback")
buttons = Buttons([submit], "row")
submit = Button("Plan trip", @ToAssistant("Plan my weekend", {viewId: "trip-form", itineraryId: "TRIP-042"}), "primary")
```

This is native Markdown again. Try selecting from the first paragraph through the form to here, then copying: the child exports its original OpenUI source.

| Streaming remains incremental | Presentation |
| --- | --- |
| Prose and code | Native TextKit |
| Table rows | Existing hosted table |
| Completed OpenUI | Retained web child |

Math keeps the existing renderer: \(E = mc^2\).

## Choose a workshop date

A date picker adds a different kind of interaction: open its calendar, move between months, and choose a day near the bottom of the popup. The surrounding document should make room for the expanded calendar. Close it to return to the compact card, then submit the date to the example's action readout.

```openui
root = Card([heading, workshopForm])
heading = CardHeader("Book a workshop", "Choose a date for a small-group design session")
workshopForm = Form("workshop", buttons, [dateField, topicField])
dateField = FormControl("Workshop date", DatePicker("workshopDate", "single"), "Open the calendar and choose a day")
topicField = FormControl("Topic", Input("topic", "For example, accessible navigation", "text", {required: true, minLength: 3}), "A short description of the session")
buttons = Buttons([submit], "row")
submit = Button("Review workshop", @ToAssistant("Review this workshop request", {viewId: "workshop-form", requestId: "WORKSHOP-DEMO"}), "primary")
```

Try entering a topic, scrolling away to another section, and returning to the form. Then resize the window: entered values should remain available while the card adapts to the text width. This second form keeps its values separately from the weekend planner above. Use the keyboard to move between its text field and submission button; open the calendar with the pointer.

## A read-only planning summary

A component does not need to be a form. This card combines a heading and formatted content into a short response, including a table and a checklist. Its fictional values describe the same weekend-planning scenario as the first form.

```openui
root = Card([heading, summary])
heading = CardHeader("Weekend outline", "An example response with several kinds of formatted content")
summary = TextContent("## Saturday morning\n\nStart with a **riverside walk**, stop for coffee, and leave the afternoon open. This is a fictional itinerary for exploring the component renderer.\n\n| Stop | Duration |\n| --- | --- |\n| Riverside loop | 45 minutes |\n| Coffee break | 30 minutes |\n| Market visit | 60 minutes |\n\n### Bring along\n\n- Comfortable shoes\n- A water bottle\n- A light jacket\n\nThe plan deliberately leaves room for changes.")
```

This paragraph returns to native Markdown. A selection can start here, cross the card, and continue into the next section. Copying the selected component preserves its original OpenUI source alongside the surrounding prose.

## Send feedback to the example

The final form uses the same action callback with a different payload. Enter a short subject and a longer comment. Required-field validation should happen in the form, while a completed submission updates the readout above the document.

```openui
root = Card([heading, feedbackForm])
heading = CardHeader("Share feedback", "Try required fields, keyboard focus, and a second independent form")
feedbackForm = Form("feedback", buttons, [subjectField, commentField])
subjectField = FormControl("Subject", Input("subject", "What did you try?", "text", {required: true, minLength: 3}), "Give the feedback a short title")
commentField = FormControl("Comment", Input("comment", "Describe what you noticed", "text", {required: true, minLength: 8}), "Use fictional details for this example")
buttons = Buttons([submit], "row")
submit = Button("Preview feedback", @ToAssistant("Preview this example feedback", {viewId: "feedback-form", category: "renderer-demo"}), "primary")
```

Submitting these examples reports an action to the example app; the app displays that action locally. The cards demonstrate component interaction rather than booking a real workshop or sending feedback to another service.

## Things to try

1. Move through the fields and buttons using the keyboard, then submit one form.
2. Leave another form partly filled in, scroll to the summary, and return to it.
3. Open the calendar, select a date, and check that the following Markdown remains readable.
4. Switch to **Source** to inspect the component definitions, or use **Stream** and **Replay** to watch complete cards arrive between native paragraphs.

On macOS these fences render as interactive components. On iOS their source remains visible, so the same document still explains the structure of each example.
