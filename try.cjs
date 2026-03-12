/* eslint-disable */

// Build this via `npm run build`

console.log('Requiring notify addon...');
const { notify } = require('bindings')('notifier');

console.log('Calling notify...');
notify(
    {
        title: 'Noman Notification',
        message: 'This is a test notification from Noman.',
        timeout: 30,
        actions: 'Open'
    },
    function (err, _response, metadata) {
        console.log('got metadata', metadata);

        if (err) {
            console.log('Notification error:', err);
            return;
        }
    }
);
