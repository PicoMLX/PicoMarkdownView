# Interactive OpenUI

This paragraph streams as native Markdown. The form appears when its OpenUI fence completes. Enter your name and choose **Plan trip** to see the action above the document.

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
