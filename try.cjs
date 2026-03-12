/* eslint-disable */

// Build this via `npm run build`

console.log('Requiring notify addon...');
const { notify } = require('bindings')('notifier');

console.log('Calling notify...');
setInterval(() => {
    console.log('Sanity');
}, 1000);
notify(
    {
        title: 'Noman Notification',
        message: 'This is a test notification from Noman.',
        timeout: 1,
        actions: 'Open'
    },
    function (err, _response, metadata) {
        console.log('got metadata', metadata);

        if (err) {
            // Notification error: [Error: The operation couldn’t be completed. (UNErrorDomain error 1.)]
            console.log('Notification error:', err);
            return;
        }
    }
);
