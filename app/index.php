<?php
// The "real system": a toy gift card service in plain PHP and SQLite, the size
// of a controller. It has two bugs on purpose; the README says which.
//
// Run it with: php -S localhost:8080 app/index.php

declare(strict_types=1);

$db = new PDO('sqlite:' . __DIR__ . '/cards.sqlite');
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$db->exec('PRAGMA foreign_keys = ON');

function card(PDO $db): array
{
    return $db->query('SELECT * FROM cards WHERE id = 1')->fetch(PDO::FETCH_ASSOC);
}

function reply(string $body): void
{
    header('Content-Type: text/plain');
    echo $body;
}

$amount = (int) ($_GET['amount'] ?? 0);

switch (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH)) {
    case '/reset':
        $db->exec(file_get_contents(__DIR__ . '/schema.sql'));
        $db->exec("INSERT INTO cards (id, status, balance) VALUES (1, 'available', 0)");
        reply('Ok');
        break;

    case '/balance':
        reply('Funds ' . card($db)['balance']);
        break;

    case '/sell':
        if (card($db)['status'] !== 'available') {
            reply('AlreadySold');
            break;
        }
        $db->prepare("UPDATE cards SET status = 'sold', balance = ? WHERE id = 1")->execute([$amount]);
        reply('Ok');
        break;

    case '/redeem':
        $card = card($db);
        if ($card['status'] === 'available') {
            reply('NotSold');
        } elseif ($card['status'] === 'expired') {
            reply('IsExpired');
        } elseif ($amount > $card['balance']) {
            reply('Insufficient');
        } else {
            $db->beginTransaction();
            $db->prepare('UPDATE cards SET balance = balance - ? WHERE id = 1')->execute([$amount]);
            $db->prepare('INSERT INTO redemptions (card_id, amount) VALUES (1, ?)')->execute([$amount]);
            $db->commit();
            reply('Ok');
        }
        break;

    case '/reverse':
        if (card($db)['status'] === 'available') {
            reply('NotSold');
            break;
        }
        $last = $db->query('SELECT * FROM redemptions WHERE card_id = 1 ORDER BY id DESC LIMIT 1')
            ->fetch(PDO::FETCH_ASSOC);
        if (!$last) {
            reply('NothingToReverse');
            break;
        }
        $db->beginTransaction();
        $db->prepare('UPDATE cards SET balance = balance + ? WHERE id = 1')->execute([$last['amount']]);
        $db->prepare("UPDATE redemptions SET reversed_at = datetime('now') WHERE id = ?")->execute([$last['id']]);
        $db->commit();
        reply('Ok');
        break;

    case '/expire':
        $status = card($db)['status'];
        if ($status === 'sold') {
            $db->exec("UPDATE cards SET status = 'expired' WHERE id = 1");
            reply('Ok');
        } else {
            reply($status === 'available' ? 'NotSold' : 'IsExpired');
        }
        break;

    default:
        http_response_code(404);
        reply('not found');
}
