<?php

namespace App\Edge;

use DateTime;

interface Logger {
    public function log(string $message): void;
}

trait TimestampTrait {
    public function now(): DateTime {
        return new DateTime();
    }
}

enum Status {
    case ACTIVE;
    case DISABLED;
}

class UserService {
    use TimestampTrait;

    public const DEFAULT_ROLE = "user";

    private int $maxUsers;

    public function __construct(int $maxUsers) {
        $this->maxUsers = $maxUsers;
    }

    public function log(string $message): void {
    }
}

function makeService(int $maxUsers): UserService {
    return new UserService($maxUsers);
}
